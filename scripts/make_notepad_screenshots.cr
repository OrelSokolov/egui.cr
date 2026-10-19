# Notepad test screenshots through Egui::Capybara — a pure-event
# narrative in five shots, no window, no real mouse (every click and
# keystroke below is a synthesized in-app Event the Context consumes):
#
#   EGUI_EMBEDDED=1 crystal run scripts/make_notepad_screenshots.cr -- [outdir]
#
#   01-typed       «привет» typed as the first line of the welcome tab
#   02-two-lines   Enter, «Привет,» — the same tab, two lines
#   03-new-tab     the «+» caption button clicked (event-driven), the
#                  new tab types its own first line
#   04-menu-open   the Settings menu bar button clicked — the menu
#   05-settings    the «Settings…» item clicked — the settings page
#
# The script prints per-shot and total wall time: five full app
# sessions with real font rasterization run in well under a second
# (compile time excluded).

require "../src/egui"
require "../src/egui/capybara"
require "../src/egui/capybara/fonts"
require "../examples/notepad"

OUTDIR = ARGV[0]? || "screenshots"
Dir.mkdir_p(OUTDIR)

TITLE = "egui-cr — notepad"

# The sokol frame prologue for a borderless notepad window: the Win11
# chrome (caption strip with the app's tab hook + control buttons)
# paints BEFORE app frames — exactly what the backend's produce_frame
# does.
CHROME = ->(ctx : Egui::Context) do
  ctx.inspector.before_update if ctx.inspector_enabled?
  Egui::WindowFrame.show(ctx, TITLE, Egui::WindowFrame::Style::Windows)
end

def notepad_session
  Egui::WindowFrame.icon = {rgba: ICON_64_RGBA, width: 64, height: 64}
  app = NotepadApp.new([] of String)
  Egui::Capybara::Fonts.install!(app.ctx)
  session = Egui::Capybara::Session.new(app, width: 800, height: 600)
  session.before_update = CHROME
  session.idle(2) # a frame with the chrome prologue on top
  session
end

def shot(session, name, t0)
  session.screenshot(File.join(OUTDIR, "notepad-#{name}.png"))
  puts "  #{name}: #{"%.0f" % (Time.instant - t0).total_milliseconds} ms"
end

t_start = Time.instant
puts "notepad Capybara screenshots → #{OUTDIR}/notepad-*.png"

# --- 01: type «привет» — the first line ---------------------------------
# The welcome tab's textarea takes focus by itself (focus follows the
# tab selection), so typing goes straight into it: one text-input
# event, no clicking at all.
t = notepad_session
t.type("привет")
t.expect_text("привет")
shot(t, "01-typed", t_start)

# --- 02: Enter, «Привет,» — the same tab now has two lines ---------------
t.press_key(:enter)
t.type("Привет,")
t.expect_text("привет")     # line 1…
t.expect_text("Привет,")    # …and line 2 (the textarea paints per line)
shot(t, "02-two-lines", t_start)

# --- 03: new tab via the «+» caption button, its own first line ----------
# A real click — but an EVENT click: press/release at the NewTab card's
# center, exactly the gesture Memory classifies, no OS input involved.
t.click("NewTab")
t.type("привет")
t.expect_text("untitled")
shot(t, "03-new-tab", t_start)

# --- 04: the Settings menu, open ------------------------------------------
t.click("Settings")
t.expect_text("Settings…")
shot(t, "04-menu-open", t_start)

# --- 05: into the settings page -------------------------------------------
t.click("Settings…")
t.expect_text("Editor font size")
shot(t, "05-settings", t_start)

total = (Time.instant - t_start).total_milliseconds
puts "total: #{"%.0f" % total} ms for 5 shots (one session, pure events)"
