// egui-cr Android IME bridge (ANDROID_SUPPORT_PLAN.md, phase 5).
//
// NativeActivity has no InputConnection, so the system keyboard falls back
// to "raw key events" — no autocorrect, no composing preview, no non-Latin
// layouts. This activity subclass attaches a zero-size editor view whose
// InputConnection forwards IME text ops to the native shim (SDL's approach):
//
//   commitText / setComposingText / deleteSurroundingText / performEditorAction
//     → Java_..._native* (backend/sokol_shim.c, mutex-queued — the callbacks
//       arrive on the Java UI thread and must not touch Crystal) → drained
//       by Sokol#on_frame on sokol's loop thread → Egui::Event.
//
// The activity still loads the pure-native .so via the standard
// android.app.lib_name meta-data; sokol's ANativeActivity_onCreate is
// inherited untouched. Built to classes.dex with javac+d8 (see
// tmp/android/build_apk.sh).
package com.eguicr.ime;

import android.app.NativeActivity;
import android.content.Context;
import android.os.Bundle;
import android.text.InputType;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;

public class EguiCrActivity extends NativeActivity {
    static EguiCrActivity instance;
    private DummyEdit edit;

    // Editor-state mirror: the focused egui-cr field's text + selection,
    // pushed from native (egui_cr_android_ime_set_editor) whenever it
    // changes. Native editors keep the IME informed this way
    // (imm.updateSelection + real getText*Cursor answers) — Gboard's
    // hold-to-delete stalls without it. Offsets are UTF-16 (Java string
    // indexes). Volatile: written from the native thread, read from the
    // UI thread.
    static volatile String editorText = "";
    static volatile int editorSelStart = 0, editorSelEnd = 0;

    // Called from native when the focused field's state changed.
    public static void editorStateChanged(final String text, final int selStart,
                                          final int selEnd) {
        editorText = text;
        editorSelStart = selStart;
        editorSelEnd = selEnd;
        final EguiCrActivity a = instance;
        if (a == null) return;
        a.runOnUiThread(new Runnable() {
            @Override public void run() {
                if (a.edit == null) return;
                InputMethodManager imm = (InputMethodManager)
                    a.getSystemService(Context.INPUT_METHOD_SERVICE);
                // -1/-1: no composing region reported (we compose in the
                // widget, the IME's own span is transient bookkeeping).
                imm.updateSelection(a.edit, selStart, selEnd, -1, -1);
            }
        });
    }

    // Register the .so with the VM: NativeActivity dlopens it directly,
    // bypassing the VM's native-library table — without this the VM can't
    // resolve the native* methods below (UnsatisfiedLinkError). The
    // subsequent dlopen in NativeActivity just bumps the refcount.
    static {
        System.loadLibrary("egui_cr_android");
    }

    // Field kinds mirrored from Egui::TextInputKind (src/egui/memory.cr).
    static final int KIND_PLAIN = 0, KIND_PASSWORD = 1, KIND_MULTILINE = 2, KIND_NUMBER = 3;
    // Enter-key actions mirrored from Egui::TextInputAction.
    static final int ACTION_NONE = 0, ACTION_DONE = 1, ACTION_GO = 2, ACTION_SEARCH = 3,
                     ACTION_SEND = 4, ACTION_NEXT = 5;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        instance = this;
    }

    // Called from the native shim (sokol loop thread) via JNI.
    public static void showKeyboard(final int kind, final int action) {
        final EguiCrActivity a = instance;
        if (a == null) return;
        a.runOnUiThread(new Runnable() {
            @Override public void run() { a.showInternal(kind, action); }
        });
    }

    public static void hideKeyboard() {
        final EguiCrActivity a = instance;
        if (a == null) return;
        a.runOnUiThread(new Runnable() {
            @Override public void run() { a.hideInternal(); }
        });
    }

    private boolean keyboardWanted = false; // last request was show
    private int showRetries = 0;
    private int pendingKind = KIND_PLAIN, pendingAction = ACTION_DONE;

    private void showInternal(int kind, int action) {
        pendingKind = kind;
        pendingAction = action;
        if (edit == null) {
            edit = new DummyEdit(this);
            // Zero-size and transparent: never visible, never hit-testable —
            // it only exists so the IMM has an editor to talk to.
            ViewGroup decor = (ViewGroup) getWindow().getDecorView();
            decor.addView(edit, new ViewGroup.LayoutParams(0, 0));
        }
        edit.setField(kind, action);
        keyboardWanted = true;
        showRetries = 0;
        tryShow();
    }

    // showSoftInput silently fails while the IMM doesn't serve our view —
    // typically right after the window regains focus (returning from
    // HOME/another app): the request reaches the client but dies at
    // PHASE_CLIENT_VIEW_SERVED. Retry a few times; onWindowFocusChanged
    // below is the other recovery point.
    private void tryShow() {
        InputMethodManager imm =
            (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
        boolean f = edit.requestFocus();
        if (!f && showRetries == 2) {
            // The editor view's focus state went stale across the window
            // focus loss (every canTakeFocus() condition checks out yet
            // requestFocus() refuses) — a fresh view takes it back.
            ViewGroup decor = (ViewGroup) getWindow().getDecorView();
            decor.removeView(edit);
            edit = new DummyEdit(this);
            decor.addView(edit, new ViewGroup.LayoutParams(0, 0));
            edit.setField(pendingKind, pendingAction);
            f = edit.requestFocus();
        }
        boolean ok = f && imm.showSoftInput(edit, 0);
        android.util.Log.i("egui_cr", "ime: tryShow focus=" + f
            + " shown=" + ok + " retry=" + showRetries);
        if (!ok && showRetries < 8) {
            showRetries++;
            edit.postDelayed(new Runnable() {
                @Override public void run() {
                    if (keyboardWanted) tryShow();
                }
            }, 250);
        }
    }

    // The IMM re-evaluates the served view when the window regains
    // focus — a show request issued while unfocused never lands, so
    // repeat it here if the keyboard is still wanted.
    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus && keyboardWanted && edit != null) {
            showRetries = 0;
            edit.post(new Runnable() {
                @Override public void run() { tryShow(); }
            });
        }
    }

    private void hideInternal() {
        keyboardWanted = false;
        if (edit == null) return;
        InputMethodManager imm =
            (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
        imm.hideSoftInputFromWindow(edit.getWindowToken(), 0);
        edit.clearFocus();
    }

    // The editor the IMM binds to. A plain View (not TextView): all state
    // lives in the egui-cr widget, we only implement the transport.
    private static class DummyEdit extends View {
        private int inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_NORMAL;
        private int imeOptions = EditorInfo.IME_ACTION_DONE;

        DummyEdit(Context ctx) {
            super(ctx);
            setFocusable(true);
            setFocusableInTouchMode(true);
        }

        void setField(int kind, int action) {
            switch (kind) {
                case KIND_PASSWORD:
                    inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD;
                    break;
                case KIND_MULTILINE:
                    inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE;
                    break;
                case KIND_NUMBER:
                    inputType = InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL;
                    break;
                default:
                    inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_NORMAL;
                    break;
            }
            switch (action) {
                case ACTION_NONE:   imeOptions = EditorInfo.IME_ACTION_NONE; break;
                case ACTION_GO:     imeOptions = EditorInfo.IME_ACTION_GO; break;
                case ACTION_SEARCH: imeOptions = EditorInfo.IME_ACTION_SEARCH; break;
                case ACTION_SEND:   imeOptions = EditorInfo.IME_ACTION_SEND; break;
                case ACTION_NEXT:   imeOptions = EditorInfo.IME_ACTION_NEXT; break;
                default:            imeOptions = EditorInfo.IME_ACTION_DONE; break;
            }
            // Native apps don't get the landscape full-screen extract editor;
            // adjustResize in the manifest keeps our own widgets visible.
            imeOptions |= EditorInfo.IME_FLAG_NO_EXTRACT_UI | EditorInfo.IME_FLAG_NO_FULLSCREEN;
        }

        @Override
        public boolean onCheckIsTextEditor() {
            return true;
        }

        @Override
        public InputConnection onCreateInputConnection(EditorInfo outAttrs) {
            outAttrs.inputType = inputType;
            outAttrs.imeOptions = imeOptions;
            // The egui-cr widget owns the text; no initial selection/caps
            // hints for v1 (autocorrect still works per-tap).
            return new EguiCrInputConnection(this, true);
        }
    }

    // SDL-style composing bookkeeping: the IME rewrites the composing span
    // on every autocorrect step. We remember how many chars belong to the
    // current composing region; a new setComposingText first deletes them,
    // then commits the updated text — egui.cr just sees plain edits.
    private static class EguiCrInputConnection extends BaseInputConnection {
        private int composingLen = 0;

        EguiCrInputConnection(View target, boolean fullEditor) {
            super(target, fullEditor);
        }

        // Editor queries served from the native-pushed mirror — this is
        // what native editors do and what the IME's hold-delete /
        // word-delete / autocorrect logic reads.
        @Override
        public CharSequence getTextBeforeCursor(int n, int flags) {
            String t = editorText;
            int end = editorSelStart;
            int start = Math.max(0, end - n);
            if (end > t.length()) end = t.length();
            if (start > end) start = end;
            return t.substring(start, end);
        }

        @Override
        public CharSequence getTextAfterCursor(int n, int flags) {
            String t = editorText;
            int start = editorSelEnd;
            if (start > t.length()) start = t.length();
            int end = Math.min(t.length(), start + n);
            return t.substring(start, end);
        }

        @Override
        public CharSequence getSelectedText(int flags) {
            String t = editorText;
            int start = editorSelStart, end = editorSelEnd;
            if (start == end) return null;
            if (start > t.length() || end > t.length()) return null;
            return t.substring(start, end);
        }

        @Override
        public boolean commitText(CharSequence text, int newCursorPosition) {
            // A commit while composing flushes the preview as-is first —
            // the IME's final commit replaces the whole span.
            composingLen = 0;
            if (text != null && text.length() > 0) nativeCommitText(text.toString());
            return true;
        }

        @Override
        public boolean setComposingText(CharSequence text, int newCursorPosition) {
            for (int i = 0; i < composingLen; i++) nativeDeleteText(1);
            composingLen = 0;
            if (text != null && text.length() > 0) {
                nativeCommitText(text.toString());
                composingLen = text.length();
            }
            return true;
        }

        @Override
        public boolean deleteSurroundingText(int beforeLength, int afterLength) {
            // While composing, backspace shrinks the span (setComposingText
            // above); a deleteSurroundingText here targets committed text.
            composingLen = 0;
            for (int i = 0; i < beforeLength; i++) nativeDeleteText(1);
            // afterLength is meaningless for egui's caret-at-end semantics.
            return true;
        }

        @Override
        public boolean performEditorAction(int actionCode) {
            nativeEditorAction(actionCode);
            return true;
        }

        @Override
        public boolean finishComposingText() {
            // Composing accepted as typed — the span becomes plain text.
            composingLen = 0;
            return true;
        }
    }

    // Implemented in backend/sokol_shim.c; queue records for the sokol
    // loop thread (never call Crystal from here — this is the UI thread).
    native static void nativeCommitText(String text);
    native static void nativeDeleteText(int count);
    native static void nativeEditorAction(int actionCode);
}
