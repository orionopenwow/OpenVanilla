"""UX walk-through of Herald Autopilot under a real Tk window: click through every page the way a
player would, screenshot each step, and fail loudly on any Tk error.

    xvfb-run -s "-screen 0 1280x800x24" python tests/ui_autopilot_walkthrough.py OUT_DIR

Steps: first-run question -> say yes -> Play page -> pick Quest -> START (demo) -> let it run ->
Session page -> Rules (change one) -> Sim (run) -> Settings (preview what's shared) -> STOP.
"""
import os
import subprocess
import sys
import tempfile
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "autopilot"))

import herald_autopilot as ha  # noqa: E402

OUT = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp()
os.makedirs(OUT, exist_ok=True)
errors = []


def report(*args):
    errors.append("".join(traceback.format_exception(*args)))


folder = tempfile.mkdtemp()
app = ha.App(demo=True, folder=folder, chrome=True)
app.report_callback_exception = report
app.link.speed = 6.0     # a fast demo so a few seconds show a real run
shots = []


def shot(name):
    app.update()
    path = os.path.join(OUT, name + ".png")
    x, y = app.winfo_rootx(), app.winfo_rooty()
    subprocess.run(["import", "-window", "root", "-crop", f"{ha.W}x{ha.H}+{x}+{y}", path], check=True)
    shots.append(path)


def find_text(s):
    """The canvas item whose text is s (the click target a player would use)."""
    for it in app.cv.find_all():
        if app.cv.type(it) == "text" and app.cv.itemcget(it, "text") == s and app.cv.itemcget(it, "fill") != "#000000":
            return it
        if app.cv.type(it) == "image" and app.labels.get(it) == s:
            return it
    raise AssertionError(f"no '{s}' on screen")


def click_text(s):
    it = find_text(s)
    x0, y0, x1, y1 = app.cv.bbox(it)
    app.cv.event_generate("<Button-1>", x=(x0 + x1) // 2, y=(y0 + y1) // 2)
    app.update()


def check(cond, msg):
    if not cond:
        errors.append("CHECK FAILED: " + msg)


steps = []


def step(delay):
    def deco(fn):
        steps.append((delay, fn))
        return fn
    return deco


@step(1600)
def s1():
    shot("01_first_run_question")
    check(app.cv.find_withtag("modal"), "first-run question is shown")
    click_text("YES, SHARE")
    check(app.learner.consent is True, "consent saved")
    check(not app.cv.find_withtag("modal"), "question closed")


@step(300)
def s2():
    shot("02_play_ready")
    check("READY" in [app.cv.itemcget(i, "text") if app.cv.type(i) == "text" else app.labels.get(i) for i in app.cv.find_withtag("dyn")], "status READY")
    click_text("Quest")
    check(app.goal == "quest", "goal picked")


@step(300)
def s3():
    click_text("START")
    check(app.running, "running after START")


@step(4500)
def s4():
    shot("03_play_running")
    check(app.session and (app.session.kills > 0 or app.session.xp > 0), "the demo run made progress")
    check(app.logbox and len(app.logbox.get("1.0", "end")) > 100, "log has lines")
    click_text("Session")


@step(500)
def s5():
    shot("04_session")
    click_text("Rules")


@step(400)
def s6():
    shot("05_rules")
    cls, level, rules = app.current_rules()
    rule = ha.core.RULE_BY_KEY["rest_hp"]
    app.set_rule(rule, "50%")
    check(app.current_rules()[2]["rest_hp"] == 50, "rule change applied")
    check(app.link.rules.get("rest_hp") == 50, "rule reached the running demo")
    check(app.learner.pending() >= 1, "rule change was recorded for learning")


@step(400)
def s7():
    shot("06_rules_changed")
    click_text("Sim")


@step(400)
def s8():
    e = app.sim_entries["b"].get("ap") or app.sim_entries["b"].get("spell_power")
    v = float(e.get())
    e.delete(0, "end")
    e.insert(0, str(v + 120))
    click_text("RUN SIM")


@step(4000)
def s9():
    shot("07_sim_result")
    check(app.sim_result and app.sim_result["pct"] > 0, "more attack power sims higher")
    click_text("Settings")


@step(400)
def s10():
    click_text("WHAT'S SHARED")
    txt = app.preview_box.get("1.0", "end")
    check('"records"' in txt, "preview shows the batch")
    check("Herald" not in txt, "the character's name is not in what's shared")
    shot("08_settings_preview")
    click_text("Play")


@step(400)
def s11():
    click_text("STOP")
    check(not app.running, "stopped")
    check(app.learner.pending() >= 1, "learning queue kept its records")


@step(400)
def s12():
    shot("09_stopped")
    app.quit_app()


def run_steps(i=0):
    if i >= len(steps):
        return
    delay, fn = steps[i]

    def go():
        try:
            fn()
        except Exception:
            errors.append(f"step {fn.__name__}: " + traceback.format_exc())
            try:
                shot(f"ERR_{fn.__name__}")
            except Exception:
                pass
        run_steps(i + 1)
    app.after(delay, go)


run_steps()
app.mainloop()
print("\n".join(shots))
if errors:
    print("\n".join(errors))
    sys.exit(1)
print("UI walk-through: all steps passed")
