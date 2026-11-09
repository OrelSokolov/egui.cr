// KDE widget oracle renderer — native Qt6/Breeze → PNG.
//
// The Qt twin of oracle/macos/render.swift: one flat 480×160 sheet
// per widget, light Breeze, no window chrome, no focus, no hover.
// Widgets sit at the same skeleton as the macOS/GTK sheets — first
// column x=24, second x=250, vertically centered on the y=80 midline
// — so the egui twin harness (scripts/make_kde_oracle_shots.cr)
// renders against the same geometry.
//
// Fully headless: QT_QPA_PLATFORM=offscreen (set below) — widgets
// render into pixmaps without any display, nothing flashes on the
// user's screen. Capture = QWidget::render into a QImage.
//
//   cd oracle/qt && make   # → png/<sheet>.png
//
// Requires: qt6-base-dev, kde-style-breeze (the Breeze QStyle plugin;
// without it Qt falls back to Fusion and the render aborts).

#include <QApplication>
#include <QButtonGroup>
#include <QCheckBox>
#include <QComboBox>
#include <QHBoxLayout>
#include <QImage>
#include <QLabel>
#include <QLineEdit>
#include <QPainter>
#include <QProgressBar>
#include <QPushButton>
#include <QRadioButton>
#include <QSlider>
#include <QSpinBox>
#include <QStyle>
#include <QStyleFactory>
#include <QToolButton>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QWidget>
#include <QDir>
#include <QList>
#include <cstdio>
#include <string_view>

namespace {

constexpr int SHEET_W = 480, SHEET_H = 160;
constexpr int COL1_X = 24, COL2_X = 250, MID_Y = 80;

struct Sheet {
    const char *name;
    QWidget *widget; // one shared host, repopulated per sheet
};

// One sheet host: a plain QWidget with absolute child geometry.
class Host : public QWidget {
public:
    Host() { setFixedSize(SHEET_W, SHEET_H); setAutoFillBackground(true); }

    void place(QWidget *child, int x, int h) {
        // Vertical center on the midline, GTK-sheet style. Children
        // join AFTER the host's show() — offscreen never propagates
        // visibility to late children, so show each one explicitly.
        child->show();
        // No keyboard focus ever: Breeze paints the focus state (blue
        // entry border) and offscreen ignores clearFocus() — the
        // sheets are the neutral no-focus state.
        child->setFocusPolicy(Qt::NoFocus);
        child->setGeometry(x, MID_Y - h / 2, child->sizeHint().width(), h);
    }
};

int childHeight(QWidget *child) {
    return std::max(child->sizeHint().height(), child->minimumSizeHint().height());
}

// One sheet's widgets, parented to `parent`, with their column x —
// the caller places them (oracle: Host::place; gallery: a row box).
// The segmented group comes as ONE container (linked buttons hug).
QList<QPair<int, QWidget *>> makeSheetWidgets(QWidget *parent,
                                              const QString &name) {
    QList<QPair<int, QWidget *>> out;

    if (name == "button") {
        out.append({COL1_X, new QPushButton("Button", parent)});
        out.append({COL2_X, new QPushButton("OK", parent)});
    } else if (name == "checkbox") {
        auto *c1 = new QCheckBox("Check", parent); c1->setChecked(false);
        auto *c2 = new QCheckBox("Selected", parent); c2->setChecked(true);
        out.append({COL1_X, c1});
        out.append({COL2_X, c2});
    } else if (name == "radio") {
        auto *r1 = new QRadioButton("First", parent); r1->setChecked(true);
        auto *r2 = new QRadioButton("Second", parent);
        out.append({COL1_X, r1});
        out.append({COL2_X, r2});
    } else if (name == "text_field") {
        auto *e = new QLineEdit("Placeholder", parent);
        e->setFixedWidth(200);
        out.append({COL1_X, e});
    } else if (name == "search_field") {
        auto *e = new QLineEdit(parent);
        e->setPlaceholderText("Search");
        e->setFixedWidth(222);
        // Leading lens — QLineEdit's leading placeholder icon slot
        // (addAction with PlaceholderRole draws it in the field).
        e->addAction(parent->style()->standardIcon(QStyle::SP_FileDialogContentsView),
                     QLineEdit::LeadingPosition);
        out.append({COL1_X, e});
    } else if (name == "slider") {
        auto *s = new QSlider(Qt::Horizontal, parent);
        s->setRange(0, 100); s->setValue(60); s->setFixedWidth(220);
        out.append({COL1_X, s});
    } else if (name == "segmented") {
        // No native Qt segmented — linked checkable QToolButtons (the
        // standard QtWidgets grouping for pick-one-of-N), zero-gap in
        // one container so the cells hug like a linked strip.
        auto *box = new QWidget(parent);
        auto *l = new QHBoxLayout(box);
        l->setContentsMargins(0, 0, 0, 0);
        l->setSpacing(0);
        auto *group = new QButtonGroup(box);
        group->setExclusive(true);
        const char *texts[] = {"One", "Two", "Three"};
        for (int i = 0; i < 3; ++i) {
            auto *tb = new QToolButton(box);
            tb->setText(texts[i]);
            tb->setCheckable(true);
            tb->setChecked(i == 1);
            tb->setToolButtonStyle(Qt::ToolButtonTextOnly);
            // Focus ban here too — the oracle loop's place() only
            // reaches the container, and Breeze paints focus state.
            tb->setFocusPolicy(Qt::NoFocus);
            group->addButton(tb);
            l->addWidget(tb);
        }
        out.append({COL1_X, box});
    } else if (name == "popup") {
        auto *cb = new QComboBox(parent);
        cb->addItems({"First", "Second", "Third"});
        cb->setCurrentIndex(0);
        cb->setFixedWidth(200);
        out.append({COL1_X, cb});
    } else if (name == "progress") {
        auto *pb = new QProgressBar(parent);
        pb->setRange(0, 100); pb->setValue(45); pb->setFixedWidth(200);
        pb->setTextVisible(false);
        out.append({COL1_X, pb});
    } else if (name == "stepper") {
        auto *sb = new QSpinBox(parent);
        sb->setRange(0, 100); sb->setValue(42); sb->setFixedWidth(200);
        out.append({COL1_X, sb});
    } else if (name == "label") {
        auto *l1 = new QLabel("Label", parent);
        out.append({COL1_X, l1});
        auto *l2 = new QLabel("Dim label", parent);
        // Dimmed text — the disabled text color is Breeze's muted gray.
        QPalette pal = l2->palette();
        pal.setColor(QPalette::Active, QPalette::WindowText,
                     pal.color(QPalette::Disabled, QPalette::WindowText));
        l2->setPalette(pal);
        out.append({COL2_X, l2});
    }
    return out;
}

} // namespace

int main(int argc, char **argv) {
    // Headless unless `gallery` — the live twin of
    // oracle/macos/render.swift's gallery mode (a real window with
    // every sheet stacked up, interactive).
    const bool gallery = argc > 1 && std::string_view(argv[1]) == "gallery";
    if (!gallery)
        qputenv("QT_QPA_PLATFORM", "offscreen");

    QApplication app(argc, argv);
    QApplication::setStyle(QStyleFactory::create("Breeze"));
    if (QApplication::style()->objectName() != "breeze") {
        std::fprintf(stderr,
            "Breeze QStyle not available (got '%s') — install "
            "kde-style-breeze and retry.\n",
            qPrintable(QApplication::style()->objectName()));
        return 2;
    }
    // Breeze's system font: Noto Sans 10pt.
    QFont f("Noto Sans");
    f.setPointSize(10);
    QApplication::setFont(f);

    const QStringList sheets = {
        "button", "checkbox", "radio", "text_field", "search_field",
        "slider", "segmented", "popup", "progress", "stepper", "label",
    };

    if (gallery) {
        QWidget galleryWindow;
        galleryWindow.setWindowTitle(
            "Qt/Breeze Widget Gallery (native oracle)");
        auto *lay = new QVBoxLayout(&galleryWindow);
        lay->setContentsMargins(24, 12, 24, 12);
        lay->setSpacing(4);
        for (const QString &name : sheets) {
            auto *caption = new QLabel(name, &galleryWindow);
            QPalette pal = caption->palette();
            pal.setColor(QPalette::Active, QPalette::WindowText,
                         pal.color(QPalette::Disabled, QPalette::WindowText));
            caption->setPalette(pal);
            lay->addWidget(caption);
            auto *row = new QWidget(&galleryWindow);
            auto *rl = new QHBoxLayout(row);
            rl->setContentsMargins(0, 0, 0, 8);
            rl->setSpacing(28);
            for (auto [x, w] : makeSheetWidgets(row, name)) {
                w->show();
                rl->addWidget(w);
            }
            lay->addWidget(row);
        }
        galleryWindow.show();
        return app.exec();
    }

    QDir().mkpath("png");
    for (const QString &name : sheets) {
        Host host;
        host.show(); // offscreen: realizes + styles, paints nothing anywhere
        const auto widgets = makeSheetWidgets(&host, name);
        for (auto [x, w] : widgets)
            host.place(w, x, childHeight(w));
        app.processEvents();
        // Drop the automatic focus the first child grabbed: Breeze
        // paints focus rings/borders (blue entry border, dotted
        // buttons) — the sheets are the neutral no-focus state.
        if (QWidget *fw = QApplication::focusWidget()) fw->clearFocus();
        app.processEvents();

        QImage img(SHEET_W, SHEET_H, QImage::Format_ARGB32_Premultiplied);
        QPainter p(&img);
        host.render(&p);
        p.end();
        const QString out = "png/" + name + ".png";
        img.save(out);
        std::puts(qPrintable(out));
    }
    return 0;
}
