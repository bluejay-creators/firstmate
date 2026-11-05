#!/usr/bin/env bash
# Long-lived source argv for the firstmate process-to-event runner
# (registered as adapter herdr-panes, source id herdr-pane-events; see
# bin/fm-procevent-herdr-panes.sh for the adapter contract). One invocation is
# one episode: it watches the herdr socket API until ONE notable thing exists
# that the roster watcher should look at, prints a bounded report on stdout,
# and exits 0 so the runner captures that report and wakes firstmate. With no
# notable change it keeps watching; the adapter's `relisten` keeps one runner
# subscribed forever without stacking sockets.
#
# Notable things (an episode ends on the FIRST of these):
#   (a) an agent pane firstmate cannot account for (secondmates from
#       data/secondmates.md, peers.tsv labels, state/*.meta workers, manual
#       state/roster/adhoc.tsv rows): its pane id is appended to
#       state/.herdr-event-unknown.tsv, and the report asks the roster check
#       (--herdr-event-source --panes-file -) to auto-register it into
#       adhoc.tsv exactly like the 5-minute poll does;
#   (b) an agent pane ending a blocked episode it entered AFTER this listener
#       armed: the pane's visible screen is saved under
#       state/.blocked-captures/ exactly like state/peer-blocked.check.sh does;
#   (c) the herdr socket is lost / the subscription drops: the report says so
#       and exits 75 (tempfail) so the runner relistens immediately; on a
#       repeated loss the runner's own launch floor spaces the retries. The
#       herdr server itself is never restarted or stopped from here.
#
# Detection is event-driven with a slow reconcile safety net:
#   - pane.agent_detected subscription: a new agent pane is checked for roster
#     membership AND is armed with a per-pane `agent.wait <pane> --until
#     blocked` helper connection (server-side, event-driven); its reply is the
#     blocked transition. An already-blocked pane fails that wait fast
#     (agent_blocked), which the reconcile pass below owns.
#   - a full snapshot every RECONCILE_S (default 30s): roster membership for
#     panes the event stream missed, and blocked-episode detection current
#     within one reconcile period (episodes that predate the listener arm are
#     recorded silently, matching "first seen" semantics - firstmate still
#     hears about those from the ordinary roster/peer-blocked watcher checks).
#   - pane.closed removes per-pane state.
#
# Env: FM_STATE_OVERRIDE / FM_CONFIG_OVERRIDE as usual; FM_HERDR_SOCK overrides
# the socket path (default $HERDR_SOCKET_PATH or ~/.config/herdr/herdr.sock);
# FM_HERDR_EVENT_RECONCILE_S and FM_HERDR_EVENT_WAIT_TIMEOUT_S tune cadence.
set -u
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
STATE=${FM_STATE_OVERRIDE:-$SCRIPT_DIR}
CONFIG_DIR=${FM_CONFIG_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/../config" 2>/dev/null && pwd)}
HOME_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
SOCK=${FM_HERDR_SOCK:-${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}}
{ umask 077; printf 'sock=%s state=%s home_root=%s\n' "$SOCK" "$STATE" "$HOME_ROOT" > "$STATE/.herdr-pane-events.debug"; } 2>/dev/null || true
RECONCILE_S=${FM_HERDR_EVENT_RECONCILE_S:-30}
WAIT_TIMEOUT_S=${FM_HERDR_EVENT_WAIT_TIMEOUT_S:-10800}   # helper connection ceiling, re-armed on timeout
ROSTER_CHECK=${FM_HERDR_ROSTER_CHECK:-$STATE/agent-roster.check.sh}
export FM_HERDR_SOCK SOCK RECONCILE_S WAIT_TIMEOUT_S HOME_ROOT STATE CONFIG_DIR ROSTER_CHECK
unset HERDR_ENV 2>/dev/null || true   # herdr CLI only needs HERDR_SOCKET_PATH; a stale manager context must not pin us

exec python3 - <<'PY'
import glob, json, os, re, socket, subprocess, sys, threading, time

HOME = os.environ["HOME_ROOT"]
STATE = os.environ["STATE"]
CONFIG_DIR = os.environ.get("CONFIG_DIR") or os.path.join(HOME, "config")
SOCK = os.environ["SOCK"]
RECONCILE_S = float(os.environ.get("RECONCILE_S", "30"))
WAIT_TIMEOUT_S = float(os.environ.get("WAIT_TIMEOUT_S", "10800"))
ROSTER_CHECK = os.environ.get("ROSTER_CHECK")

ROSTER_DIR = os.path.join(STATE, "roster")
ADHOC = os.path.join(ROSTER_DIR, "adhoc.tsv")
BLOCKED_MARKERS = os.path.join(STATE, ".herdr-blocked")
CAPTURES = os.path.join(STATE, ".blocked-captures")
UNKNOWN_TSV = os.path.join(STATE, ".herdr-event-unknown.tsv")
os.makedirs(BLOCKED_MARKERS, mode=0o700, exist_ok=True)
os.makedirs(CAPTURES, mode=0o700, exist_ok=True)
os.makedirs(ROSTER_DIR, exist_ok=True)

LOCK = threading.Lock()
STDOUT_LOCK = threading.Lock()
detected_events = []          # pane_ids delivered by pane.agent_detected
closed_events = []            # pane_ids delivered by pane.closed
wait_results = []             # (pane_id, outcome) from agent.wait helper connections
wait_held = {}                # pane_id -> holder threading.local marker (entry alive while a helper owns the pane)
stop = threading.Event()
t0 = time.time()
last_reconcile = 0.0
socket_diag = ""

def log(msg):
    with STDOUT_LOCK:
        sys.stderr.write(f"[{time.time()-t0:8.2f}] {msg}\n")
        sys.stderr.flush()

# --- socket plumbing -------------------------------------------------------
def open_conn(timeout=None):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(SOCK)
    f = s.makefile("rw", encoding="utf-8", newline="\n")
    return s, f

def rpc(method, params, timeout=15):
    s, f = open_conn(timeout)
    try:
        f.write(json.dumps({"id": "c", "method": method, "params": params}) + "\n")
        f.flush()
        for line in f:
            d = json.loads(line)
            if d.get("id") == "c":
                return d
        return None
    finally:
        s.close()

def snapshot():
    panes = (rpc("pane.list", {}) or {}).get("result", {}).get("panes") or []
    tabs = {}
    ws = (rpc("workspace.list", {}) or {}).get("result", {}).get("workspaces") or []
    ws_labels = {}
    for w in ws:
        if w.get("workspace_id"):
            ws_labels[w["workspace_id"]] = w.get("label") or ""
        t = rpc("tab.list", {"workspace_id": w["workspace_id"]})
        for tab in ((t or {}).get("result", {}).get("tabs") or []):
            if tab.get("tab_id"):
                tabs[tab["tab_id"]] = tab
    return panes, tabs, ws_labels

# --- roster accounting (mirrors state/agent-roster.check.sh) ---------------
def strip_glyph(label):
    value = re.sub(r"\s+", " ", label or "").strip()
    while True:
        head, _, rest = value.partition(" ")
        if rest and not re.search(r"[0-9A-Za-z]", head):
            value = rest
            continue
        return value

def norm_label(title):
    return strip_glyph(title)

def build_roster():
    info_norm = {}
    try:
        with open(os.path.join(HOME, "data", "secondmates.md"), encoding="utf-8") as fh:
            sms = [m.group(1) for line in fh if (m := re.match(r"^- ([a-z0-9][a-z0-9-]*) - ", line))]
    except OSError:
        sms = []
    for sm in sms:
        info_norm[norm_label(sm)] = "secondmate"
        info_norm[norm_label("fm-" + sm)] = "secondmate"
    try:
        with open(os.path.join(STATE, "peers", "peers.tsv"), encoding="utf-8") as fh:
            for line in fh:
                if not line.strip() or line.startswith("#"):
                    continue
                cols = line.rstrip("\n").split("\t")
                if len(cols) >= 2 and cols[0] and cols[1]:
                    info_norm[norm_label(cols[1])] = "peer"
    except OSError:
        pass
    accountable = set()
    state_dirs = [STATE]
    for sm in sms:
        cand = os.path.normpath(os.path.join(HOME, "..", "secondmates", sm, "state"))
        if os.path.isdir(cand):
            state_dirs.append(cand)
    for sd in state_dirs:
        for meta in glob.glob(os.path.join(sd, "*.meta")):
            rec = {}
            try:
                with open(meta, encoding="utf-8") as fh:
                    for line in fh:
                        if "=" in line:
                            k, _, v = line.partition("=")
                            rec[k.strip()] = v.strip()
            except OSError:
                continue
            if rec.get("backend") != "herdr":
                continue
            pane = rec.get("herdr_pane_id") or ""
            if not pane:
                continue
            if ":" not in pane:
                wsid = rec.get("herdr_workspace_id") or ""
                pane = f"{wsid}:{pane}" if wsid else pane
            if pane:
                accountable.add(pane)
    known_adhoc = set()
    if os.path.isfile(ADHOC):
        try:
            with open(ADHOC, encoding="utf-8") as fh:
                for line in fh:
                    line = line.rstrip("\n")
                    if not line:
                        continue
                    cols = line.split("\t")
                    if cols[0] and cols[0] != "pane_label":
                        known_adhoc.add(norm_label(cols[0]))
        except OSError:
            pass
    info_norm["FM"] = "self"
    return info_norm, accountable, known_adhoc

# --- unknown-pane ledger ----------------------------------------------------
def known_unknowns():
    known = {}
    try:
        with open(UNKNOWN_TSV, encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if line:
                    known[line.split("\t")[0]] = line
    except OSError:
        pass
    return known

def add_unknown(pane_id, rec):
    line = "\t".join([
        pane_id,
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        (rec.get("agent") or "")[:24],
        norm_label(rec.get("title") or "")[:48],
        (rec.get("cwd") or "")[:200],
    ])
    with LOCK:
        known = known_unknowns()
        if pane_id in known:
            return False
        tmp = UNKNOWN_TSV + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            for old in known.values():
                fh.write(old + "\n")
            fh.write(line + "\n")
        os.replace(tmp, UNKNOWN_TSV)
    return True

# --- blocked-episode markers -------------------------------------------------
# Marker content carries its own episode identity: `current` armed by THIS
# boot (block events inside it are ordinary), `carried` seen before this
# listener armed (suppressed: the slow roster/peer-blocked watcher checks own
# everything that was already blocked, so this event source never storms
# firstmate with old news on every runner restart). A live-blocked pane listed
# in the most recently captured report below is additionally skipped by the
# reconcile pass, which bounds one blocked pane to one wake per handler
# acknowledgement cycle.
def marker_path(pane_id):
    return os.path.join(BLOCKED_MARKERS, re.sub(r"[^A-Za-z0-9_-]", "_", pane_id))

def in_episode(pane_id):
    return os.path.exists(marker_path(pane_id))

def episode_origin(pane_id):
    try:
        with open(marker_path(pane_id), encoding="utf-8") as fh:
            return fh.readline().strip()
    except OSError:
        return ""

def arm_episode(pane_id, origin, note):
    tmp = marker_path(pane_id) + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(origin + "\n" + note)
    os.replace(tmp, marker_path(pane_id))

def read_marker(pane_id):
    try:
        with open(marker_path(pane_id), encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""

RECENT_RESULT = os.path.join(STATE, ".herdr-pane-events.latest")

def recent_blocked_panes():
    out = set()
    try:
        with open(RECENT_RESULT, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("blocked\t"):
                    cols = line.rstrip("\n").split("\t")
                    if len(cols) >= 3:
                        out.add(cols[2])
    except OSError:
        pass
    return out

def record_episode_result(report):
    tmp = RECENT_RESULT + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(report + "\n")
    os.replace(tmp, RECENT_RESULT)

def drop_pane_state(pane_id):
    try:
        os.remove(marker_path(pane_id))
    except OSError:
        pass
    with LOCK:
        known = known_unknowns()
        if pane_id in known:
            tmp = UNKNOWN_TSV + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                for pid, old in known.items():
                    if pid != pane_id:
                        fh.write(old + "\n")
            os.replace(tmp, UNKNOWN_TSV)

# --- subscription thread -----------------------------------------------------
def subscription_main():
    global socket_diag
    retry = 0
    while not stop.is_set():
        try:
            s, f = open_conn(None)
            f.write(json.dumps({"id": "sub", "method": "events.subscribe", "params": {"subscriptions": [
                {"type": "pane.agent_detected"},
                {"type": "pane.closed"},
            ]}}) + "\n")
            f.flush()
            first = f.readline()
            d = json.loads(first)
            if d.get("error"):
                raise RuntimeError("subscribe refused: " + json.dumps(d["error"])[:200])
            log("subscription started")
            retry = 0
            for line in f:
                if stop.is_set():
                    s.close()
                    return
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                if ev.get("id") == "sub" and ev.get("error"):
                    # events_lost or similar: resubscribe and reconcile
                    socket_diag = "subscription error: " + json.dumps(ev["error"])[:200]
                    raise RuntimeError(socket_diag)
                kind = ev.get("event")
                data = ev.get("data") or {}
                pid = data.get("pane_id")
                if not pid:
                    continue
                with LOCK:
                    if kind == "pane_agent_detected":
                        detected_events.append(pid)
                    elif kind == "pane_closed":
                        closed_events.append(pid)
            s.close()
            raise RuntimeError("subscription connection closed")
        except Exception as e:  # noqa: BLE001 - every loss shape relistens the same
            socket_diag = str(e)[:300]
            if stop.is_set():
                return
            retry += 1
            if retry <= 3:
                log("subscription lost (%s); resubscribing" % socket_diag)
            if retry > 30:
                socket_diag = "subscription cannot reconnect: " + socket_diag
                return
            stop.wait(min(2 * retry, 15))

def wait_helper(pid):
    """One server-side blocked wait per agent pane. Its reply IS the blocked transition."""
    outcome = None
    while not stop.is_set():
        try:
            d = rpc("agent.wait", {"target": pid, "until": ["blocked"], "timeout_ms": int(WAIT_TIMEOUT_S * 1000)}, timeout=WAIT_TIMEOUT_S + 30)
        except Exception as e:  # noqa: BLE001
            outcome = "wait-error:%s" % str(e)[:120]
        else:
            if d is None:
                outcome = "wait-closed"
            elif d.get("error"):
                outcome = "wait-error:%s" % (d["error"].get("code") or "?")
            else:
                outcome = "blocked"
        if outcome == "blocked":
            with LOCK:
                wait_results.append((pid, outcome))
            return
        # error shapes: agent gone, pane gone, or already-blocked ambiguity.
        code = outcome.split(":", 1)[1] if outcome and ":" in outcome else outcome
        if code in ("agent_not_found", "pane_not_found", "agent_released", "pane_closed"):
            return
        # Ambiguity (incl. agent_blocked): hand to the reconcile pass, which reads live state.
        with LOCK:
            wait_results.append((pid, "recheck"))
        return

def hold_wait(pid):
    with LOCK:
        if pid in wait_held:
            return False
        wait_held[pid] = True
    threading.Thread(target=_wait_helper_guard, args=(pid,), daemon=True).start()
    return True

def _wait_helper_guard(pid):
    try:
        wait_helper(pid)
    except Exception as e:  # noqa: BLE001
        log("wait helper %s crashed: %s" % (pid, str(e)[:120]))
    finally:
        with LOCK:
            wait_held.pop(pid, None)

def drain_wait_results(panes_by_id):
    out = []
    while True:
        with LOCK:
            if not wait_results:
                break
            pid, outcome = wait_results.pop(0)
        if outcome == "blocked":
            rec = panes_by_id.get(pid) or {}
            out.append((pid, rec.get("agent_status"), rec))
        else:  # recheck
            rec = panes_by_id.get(pid)
            if rec is not None:
                out.append((pid, rec.get("agent_status"), rec))
            hold_if_agent(pid, rec)
    return out

def hold_if_agent(pid, rec):
    if rec and (rec.get("agent") or rec.get("agent_session")):
        hold_wait(pid)

# --- name for reporting -------------------------------------------------------
def display_name(rec, tabs, ws_labels):
    title = norm_label(rec.get("title") or "")
    if title:
        return title
    tab = tabs.get(rec.get("tab_id") or "") or {}
    lab = strip_glyph(tab.get("label") or "")
    if lab:
        return lab
    return ws_labels.get(rec.get("workspace_id") or "") or rec.get("pane_id") or "?"

def pane_record(p, tabs):
    return {
        "pane_id": p.get("pane_id") or "",
        "agent": p.get("agent") or ((p.get("agent_session") or {}).get("agent")) or "",
        "agent_status": p.get("agent_status") or "",
        "title": p.get("terminal_title_stripped") or p.get("terminal_title") or (tabs.get(p.get("tab_id") or "") or {}).get("label") or "",
        "cwd": p.get("cwd") or p.get("foreground_cwd") or "",
        "workspace_id": p.get("workspace_id") or "",
        "tab_id": p.get("tab_id") or "",
    }

def save_capture(pid):
    key = re.sub(r"[^A-Za-z0-9_-]", "_", pid)
    dest = os.path.join(CAPTURES, "%s-%d.txt" % (key, int(time.time())))
    try:
        subprocess.run(["herdr", "pane", "read", pid, "--source", "visible"],
                       stdout=open(dest, "w"), stderr=subprocess.DEVNULL,
                       timeout=20, check=False)
        return os.path.basename(dest)
    except Exception:  # noqa: BLE001
        return ""

def main():
    global last_reconcile, socket_diag
    threading.Thread(target=subscription_main, daemon=True).start()
    # Boot baseline: everything live when this listener arms belongs to the
    # SLOW checks' first pass (roster auto-registration, pre-existing blocked
    # episodes). The event source reports only what CHANGES after this point,
    # so a runner restart never re-announces old state.
    boot_accountable = set()
    boot_blocked = set()
    try:
        panes0, _tabs0, _ws0 = snapshot()
        if panes0 is not None:
            boot_accountable = {p.get("pane_id") for p in panes0
                                if p.get("pane_id") and (p.get("agent") or p.get("agent_session"))}
            boot_accountable.discard(None)
            for p in panes0:
                pid = p.get("pane_id") or ""
                if pid and (p.get("agent_status") or "") == "blocked" and not in_episode(pid):
                    arm_episode(pid, "carried", "blocked title=%s cap=-" % (p.get("terminal_title_stripped") or p.get("terminal_title") or ""))
                    boot_blocked.add(pid)
        log("baseline: %d agent panes, %d already blocked" % (len(boot_accountable), len(boot_blocked)))

    except Exception as e:  # noqa: BLE001 - herdr down at arm time; first episode is the loss report
        socket_diag = "boot snapshot failed: %s" % str(e)[:200]
    last_reconcile = time.time()
    blocked_reports = []     # (name, pane_id, capture_name)
    unknown_reports = []     # (name, pane_id, agent, cwd)
    while not stop.is_set():
        time.sleep(0.25)
        # pull subscription events
        with LOCK:
            det = detected_events[:]; detected_events.clear()
            cls = closed_events[:]; closed_events.clear()
        for pid in cls:
            drop_pane_state(pid)
        try:
            panes, tabs, ws_labels = snapshot()
        except Exception as e:  # noqa: BLE001 - socket unrecoverable mid-episode
            socket_diag = "snapshot failed: %s" % str(e)[:200]
            panes = None
        episode_over = False
        if panes is None:
            episode_over = True  # we owe a lost report once we can connect again
        else:
            panes_by_id = {p.get("pane_id"): p for p in panes if p.get("pane_id")}
            now = time.time()
            due_reconcile = (now - last_reconcile) >= RECONCILE_S
            if due_reconcile:
                last_reconcile = now
            info_norm, accountable, known_adhoc = build_roster()
            known_unknown = known_unknowns()
            recent_blocked = recent_blocked_panes()
            check_ids = set(det)
            if due_reconcile:
                check_ids.update(pid for pid in panes_by_id if panes_by_id[pid].get("agent") or panes_by_id[pid].get("agent_session"))
            # wait-result driven re-checks always count
            for pid, status, rec in drain_wait_results(panes_by_id):
                check_ids.add(pid)
            for pid in sorted(check_ids):
                p = panes_by_id.get(pid)
                if p is None:
                    continue
                rec = pane_record(p, tabs)
                if not (rec["agent"]):
                    continue
                hold_if_agent(pid, rec)
                norm = norm_label(rec["title"])
                accounted = pid in accountable or norm in info_norm or norm in known_adhoc
                # Baseline rule: a pane already live at arm time never joins the
                # unknown roster from this pass; the 5-minute roster check owns
                # anything this listener predates.
                if not accounted and pid not in boot_accountable and pid not in known_unknown:
                    if add_unknown(pid, rec):
                        unknown_reports.append((norm or re.sub(r"[^A-Za-z0-9-]", "", pid.replace(":", "-")), pid, rec["agent"], rec["cwd"]))
                        episode_over = True
                        known_unknown[pid] = True
                status = rec["agent_status"]
                if status == "blocked":
                    if not in_episode(pid):
                        if pid in recent_blocked:
                            # Already woke firstmate for this pane's current
                            # episode in an earlier capture: stay quiet until
                            # the pane leaves blocked, exactly like marker
                            # dedupe but surviving a runner restart.
                            arm_episode(pid, "carried", "duplicate-suppressed title=%s" % rec["title"])
                        else:
                            name = display_name(rec, tabs, ws_labels)
                            cap = save_capture(pid)
                            arm_episode(pid, "current", "blocked name=%s title=%s cap=%s" % (name, rec["title"], cap))
                            blocked_reports.append((name, pid, cap))
                            episode_over = True
                            recent_blocked.add(pid)
                elif status:
                    if in_episode(pid):
                        # left blocked: episode ends silently, marker re-arms
                        drop_marker_only(pid)
            if socket_diag.startswith("subscription cannot reconnect"):
                episode_over = True
        if episode_over:
            report = build_report(blocked_reports, unknown_reports)
            record_episode_result(report)
            with STDOUT_LOCK:
                sys.stdout.write(report + "\n")
                sys.stdout.flush()
            return

def in_episode_for_report(pid):
    return False  # unknown-pane dedup lives entirely in the durable tsv

def drop_marker_only(pid):
    try:
        os.remove(marker_path(pid))
    except OSError:
        pass

def build_report(blocked_reports, unknown_reports):
    lines = ["herdr-panes-v1"]
    lines.append("ts=%s" % time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    lines.append("uptime_s=%d" % int(time.time() - t0))
    if socket_diag:
        lines.append("socket=" + socket_diag)
    lines.append("blocked=%d unknown=%d" % (len(blocked_reports), len(unknown_reports)))
    for name, pid, cap in blocked_reports:
        lines.append("blocked\t%s\t%s\t%s" % (name, pid, cap or "-"))
    for name, pid, agent, cwd in unknown_reports:
        lines.append("unknown\t%s\t%s\t%s\t%s" % (name, pid, agent or "-", cwd or "-"))
    lines.append("roster-check\t%s" % ROSTER_CHECK)
    return "\n".join(lines)

main()
PY

