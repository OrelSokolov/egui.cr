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

import android.app.AlertDialog;
import android.app.NativeActivity;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.os.VibratorManager;
import android.text.InputType;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

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

    // Haptics (SystemPorts::Haptics): style 0 light / 1 medium /
    // 2 heavy / 3 selection; ms > 0 = a plain timed buzz. minSdk 28:
    // API 29+ uses the vendor-calibrated predefined effects (weak
    // hand-rolled one-shots don't register on many OEM actuators —
    // "only heavy vibrates"); the API 28 fallback carries strong
    // amplitudes for the same reason. VIBRATE is a normal permission.
    public static void vibrate(int style, int ms) {
        final EguiCrActivity a = instance;
        if (a == null) return;
        try {
            Vibrator v;
            if (Build.VERSION.SDK_INT >= 31) {
                VibratorManager vm = (VibratorManager)
                    a.getSystemService(Context.VIBRATOR_MANAGER_SERVICE);
                v = vm == null ? null : vm.getDefaultVibrator();
            } else {
                v = (Vibrator) a.getSystemService(Context.VIBRATOR_SERVICE);
            }
            if (v == null) { android.util.Log.i("egui_cr", "vibrate: no vibrator service"); return; }
            if (!v.hasVibrator()) { android.util.Log.i("egui_cr", "vibrate: device has no vibrator"); return; }
            if (ms > 0) {
                v.vibrate(VibrationEffect.createOneShot(ms,
                    VibrationEffect.DEFAULT_AMPLITUDE));
                android.util.Log.i("egui_cr", "vibrate: one-shot " + ms + "ms");
                return;
            }
            if (Build.VERSION.SDK_INT >= 29) {
                // Vendor-tuned presets: reliably distinct intensities.
                final int[] effects = {
                    VibrationEffect.EFFECT_CLICK,        // light
                    VibrationEffect.EFFECT_HEAVY_CLICK,  // medium (no calibrated middle preset)
                    VibrationEffect.EFFECT_HEAVY_CLICK,  // heavy
                    VibrationEffect.EFFECT_TICK,         // selection
                };
                int e = effects[Math.max(0, Math.min(3, style))];
                v.vibrate(VibrationEffect.createPredefined(e));
                android.util.Log.i("egui_cr", "vibrate: predefined effect=" + e + " style=" + style);
                return;
            }
            // API 28 fallback: strong amplitudes — weak ones (<~100)
            // are dropped or imperceptible on coin-motor devices.
            final int[][] presets = {
                {16, 130},   // light
                {26, 190},   // medium
                {36, 255},   // heavy
                {10, 100},   // selection
            };
            int[] p = presets[Math.max(0, Math.min(3, style))];
            v.vibrate(VibrationEffect.createOneShot(p[0], p[1]));
            android.util.Log.i("egui_cr", "vibrate: one-shot " + p[0] + "ms amp=" + p[1]);
        } catch (Exception e) {
            android.util.Log.i("egui_cr", "vibrate failed: " + e);
        }
    }

    // Audio route diagnostics (SystemPorts::Audio): the "play() said
    // true but nothing audible" case is almost always a zeroed media
    // stream or a silent/DND ringer state — this surfaces both.
    public static String audioDiag() {
        EguiCrActivity a = instance;
        if (a == null) return null;
        try {
            android.media.AudioManager am = (android.media.AudioManager)
                a.getSystemService(Context.AUDIO_SERVICE);
            int vol = am.getStreamVolume(android.media.AudioManager.STREAM_MUSIC);
            int max = am.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC);
            int ring = am.getRingerMode();
            String rm = ring == 0 ? "SILENT" : (ring == 1 ? "VIBRATE" : "NORMAL");
            return "music=" + vol + "/" + max + " ringer=" + rm;
        } catch (Exception e) {
            android.util.Log.i("egui_cr", "audioDiag failed: " + e);
            return null;
        }
    }

    // Share (SystemPorts::Share): ACTION_SEND text/plain chooser.
    public static boolean shareText(final String subject, final String text) {
        final EguiCrActivity a = instance;
        if (a == null) return false;
        try {
            Intent i = new Intent(Intent.ACTION_SEND);
            i.setType("text/plain");
            i.putExtra(Intent.EXTRA_SUBJECT, subject == null ? "" : subject);
            i.putExtra(Intent.EXTRA_TEXT, text == null ? "" : text);
            Intent chooser = Intent.createChooser(i, null);
            chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            a.startActivity(chooser);
            return true;
        } catch (Exception e) {
            android.util.Log.i("egui_cr", "shareText failed: " + e);
            return false;
        }
    }

    // WakeLock (SystemPorts::WakeLock): FLAG_KEEP_SCREEN_ON — the
    // cheapest screen-keep mechanism, no permission required.
    public static void keepScreenOn(final boolean on) {
        final EguiCrActivity a = instance;
        if (a == null) return;
        a.runOnUiThread(new Runnable() {
            @Override public void run() {
                try {
                    android.view.Window w = a.getWindow();
                    if (w == null) return;
                    if (on) w.addFlags(android.view.WindowManager.LayoutParams
                            .FLAG_KEEP_SCREEN_ON);
                    else w.clearFlags(android.view.WindowManager.LayoutParams
                            .FLAG_KEEP_SCREEN_ON);
                } catch (Exception e) {
                    android.util.Log.i("egui_cr", "keepScreenOn failed: " + e);
                }
            }
        });
    }

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
        // System-ports bridge: mirror the system clipboard into native
        // (the only thread allowed to read it is this one). Our own sets
        // fire the listener too — the native cache is idempotent.
        try {
            final ClipboardManager cm = (ClipboardManager)
                getSystemService(Context.CLIPBOARD_SERVICE);
            cm.addPrimaryClipChangedListener(new ClipboardManager.OnPrimaryClipChangedListener() {
                @Override public void onPrimaryClipChanged() {
                    try {
                        ClipData d = cm.getPrimaryClip();
                        if (d == null || d.getItemCount() == 0) {
                            nativeClipboardChanged(null);
                            return;
                        }
                        CharSequence t = d.getItemAt(0).coerceToText(EguiCrActivity.this);
                        nativeClipboardChanged(t == null ? null : t.toString());
                    } catch (Exception e) { /* clipboard went away */ }
                }
            });
        } catch (Exception e) { /* no clipboard service */ }
    }

    // ---- System ports (ANDROID_SUPPORT_PLAN.md, phase 7) ------------------
    // Static helpers called from backend/sokol_shim.c over JNI; results
    // that only the OS can deliver asynchronously come back through the
    // native* methods at the bottom (UI thread → mutex ring → sokol loop
    // thread drain).

    // OpenUrl: ACTION_VIEW with the default handler. Runs synchronously —
    // startActivity is binder IPC, valid from any attached thread.
    public static boolean openUrl(String url) {
        EguiCrActivity a = instance;
        if (a == null) return false;
        try {
            Intent i = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            a.startActivity(i);
            return true;
        } catch (Exception e) {
            android.util.Log.i("egui_cr", "openUrl failed: " + e);
            return false;
        }
    }

    // Notification: channel + notify; on API 33+ asks for
    // POST_NOTIFICATIONS first — until granted the system silently drops
    // the notification (the app keeps running either way).
    public static void showNotification(final String title, final String body) {
        final EguiCrActivity a = instance;
        if (a == null) return;
        a.runOnUiThread(new Runnable() {
            @Override public void run() {
                try {
                    NotificationManager nm = (NotificationManager)
                        a.getSystemService(Context.NOTIFICATION_SERVICE);
                    if (Build.VERSION.SDK_INT >= 33) {
                        if (a.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
                                != PackageManager.PERMISSION_GRANTED) {
                            a.requestPermissions(
                                new String[]{android.Manifest.permission.POST_NOTIFICATIONS}, 1002);
                            return; // this one is dropped; the next shows once granted
                        }
                        if (!nm.areNotificationsEnabled()) return;
                    }
                    NotificationChannel ch = new NotificationChannel(
                        "egui_cr", "egui-cr", NotificationManager.IMPORTANCE_DEFAULT);
                    nm.createNotificationChannel(ch);
                    Notification n = new Notification.Builder(a, "egui_cr")
                        .setSmallIcon(android.R.drawable.ic_dialog_info)
                        .setContentTitle(title)
                        .setContentText(body)
                        .setAutoCancel(true)
                        .build();
                    nm.notify(1, n);
                } catch (Exception e) {
                    android.util.Log.i("egui_cr", "notify failed: " + e);
                }
            }
        });
    }

    // MessageBox: level 0 info / 1 warning / 2 error / 3 question. With
    // confirm=1 the yes/no answer goes to nativeMsgboxResult; otherwise
    // a plain OK box (no callback).
    public static void showMessageBox(final int level, final String title,
                                      final String msg, final boolean confirm) {
        final EguiCrActivity a = instance;
        if (a == null) return;
        a.runOnUiThread(new Runnable() {
            @Override public void run() {
                try {
                    AlertDialog.Builder b = new AlertDialog.Builder(a);
                    b.setTitle(title).setMessage(msg).setCancelable(true);
                    if (confirm) {
                        b.setPositiveButton(android.R.string.yes,
                            new DialogInterface.OnClickListener() {
                                @Override public void onClick(DialogInterface d, int w) {
                                    nativeMsgboxResult(1);
                                }
                            });
                        b.setNegativeButton(android.R.string.no,
                            new DialogInterface.OnClickListener() {
                                @Override public void onClick(DialogInterface d, int w) {
                                    nativeMsgboxResult(0);
                                }
                            });
                    } else {
                        b.setPositiveButton(android.R.string.ok, null);
                    }
                    b.show();
                } catch (Exception e) {
                    android.util.Log.i("egui_cr", "msgbox failed: " + e);
                }
            }
        });
    }

    // Clipboard set (get is pull + listener — see pullClipboardText and
    // the listener in onCreate).
    public static void setClipboardText(final String text) {
        final EguiCrActivity a = instance;
        if (a == null) return;
        a.runOnUiThread(new Runnable() {
            @Override public void run() {
                try {
                    ClipboardManager cm = (ClipboardManager)
                        a.getSystemService(Context.CLIPBOARD_SERVICE);
                    cm.setPrimaryClip(ClipData.newPlainText("egui_cr", text));
                } catch (Exception e) {
                    android.util.Log.i("egui_cr", "setClipboard failed: " + e);
                }
            }
        });
    }

    // Clipboard get, synchronous with a bounded wait: the caller (the
    // native sokol thread) blocks at most `capMs` while this hops to the
    // UI thread — the only one allowed to read the system clipboard.
    // The listener in onCreate keeps the native cache fresh on stock
    // Android, but OEM builds (Huawei EMUI &c.) don't reliably fire
    // OnPrimaryClipChangedListener, so every get pulls fresh text and
    // the cache is only the fallback.
    public static String pullClipboardText() {
        final EguiCrActivity a = instance;
        if (a == null) return null;
        final String[] out = new String[1];
        final CountDownLatch done = new CountDownLatch(1);
        a.runOnUiThread(new Runnable() {
            @Override public void run() {
                try {
                    ClipboardManager cm = (ClipboardManager)
                        a.getSystemService(Context.CLIPBOARD_SERVICE);
                    ClipData d = cm.getPrimaryClip();
                    if (d != null && d.getItemCount() > 0) {
                        CharSequence t = d.getItemAt(0).coerceToText(a);
                        out[0] = t == null ? null : t.toString();
                    }
                } catch (Exception e) {
                    android.util.Log.i("egui_cr", "pullClipboard failed: " + e);
                } finally {
                    done.countDown();
                }
            }
        });
        try {
            done.await(200, TimeUnit.MILLISECONDS);
        } catch (InterruptedException e) { /* fall through: cache */ }
        return out[0];
    }

    // UserDirs: which 0 files / 1 cache / 2 home / 3 documents /
    // 4 downloads / 5 pictures / 6 music / 7 videos. Null when the
    // storage is unavailable (e.g. no external volume).
    public static String sysDir(int which) {
        EguiCrActivity a = instance;
        if (a == null) return null;
        try {
            switch (which) {
                case 0: return a.getFilesDir().getAbsolutePath();
                case 1: return a.getCacheDir().getAbsolutePath();
                case 2: return a.getFilesDir().getParentFile().getAbsolutePath();
                case 3: return extDir(a, Environment.DIRECTORY_DOCUMENTS);
                case 4: return extDir(a, Environment.DIRECTORY_DOWNLOADS);
                case 5: return extDir(a, Environment.DIRECTORY_PICTURES);
                case 6: return extDir(a, Environment.DIRECTORY_MUSIC);
                case 7: return extDir(a, Environment.DIRECTORY_MOVIES);
            }
        } catch (Exception e) { return null; }
        return null;
    }

    private static String extDir(EguiCrActivity a, String type) {
        File f = a.getExternalFilesDir(type);
        return f == null ? null : f.getAbsolutePath();
    }

    // SAF pickers (the file dialogs): kind 1 ACTION_OPEN_DOCUMENT /
    // 2 ACTION_CREATE_DOCUMENT / 3 ACTION_OPEN_DOCUMENT_TREE. The result
    // (or cancel) arrives in onActivityResult → nativeSafResult, keyed
    // by requestCode = 1000 + seq. `defaultName` pre-fills the save
    // dialog's suggested name (EXTRA_TITLE).
    public static void safStart(final int seq, final int kind, final String title,
                                final String mime, final String defaultName) {
        final EguiCrActivity a = instance;
        if (a == null) return;
        a.runOnUiThread(new Runnable() {
            @Override public void run() {
                try {
                    Intent i;
                    if (kind == 2)       i = new Intent(Intent.ACTION_CREATE_DOCUMENT);
                    else if (kind == 3)  i = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
                    else                 i = new Intent(Intent.ACTION_OPEN_DOCUMENT);
                    if (kind != 3) i.addCategory(Intent.CATEGORY_OPENABLE);
                    // MIME only for the document pickers — OEM
                    // DocumentsUI builds (Huawei &c.) reject a typed
                    // tree request with an empty picker or nothing at
                    // all; tree mode ignores MIME anyway.
                    if (kind != 3)
                        i.setType(mime == null || mime.length() == 0 ? "*/*" : mime);
                    if (kind == 2 && defaultName != null && defaultName.length() > 0)
                        i.putExtra(Intent.EXTRA_TITLE, defaultName);
                    a.startActivityForResult(i, 1000 + seq);
                } catch (Exception e) {
                    android.util.Log.i("egui_cr", "safStart failed: " + e);
                    nativeSafResult(seq, 0, null);
                }
            }
        });
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        int seq = requestCode - 1000;
        if (seq < 0 || seq > 1000000) return; // not ours
        String uri = null;
        if (resultCode == RESULT_OK && data != null && data.getData() != null)
            uri = data.getData().toString();
        nativeSafResult(seq, uri != null ? 1 : 0, uri);
    }

    // Read up to 64 KB of a content:// document as UTF-8 text — the demo's
    // "open file" preview. Null when the resolver refuses.
    public static String readUriText(String uri) {
        EguiCrActivity a = instance;
        if (a == null) return null;
        try {
            InputStream in = a.getContentResolver().openInputStream(Uri.parse(uri));
            if (in == null) return null;
            ByteArrayOutputStream bo = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int total = 0, n;
            while (total < 65536 && (n = in.read(buf)) > 0) {
                bo.write(buf, 0, n);
                total += n;
            }
            in.close();
            return new String(bo.toByteArray(), 0, total, StandardCharsets.UTF_8);
        } catch (Exception e) {
            android.util.Log.i("egui_cr", "readUriText failed: " + e);
            return null;
        }
    }

    // Camera capture (src/egui/camera.cr): the permission gate for the
    // camera2-NDK stack in the shim. requestPermissions shows the system
    // dialog on the UI thread; the answer is observed by the shim polling
    // hasCameraPermission between frames (no native callback needed).
    public static boolean hasCameraPermission() {
        EguiCrActivity a = instance;
        if (a == null) return false;
        try {
            return a.checkSelfPermission(android.Manifest.permission.CAMERA)
                    == PackageManager.PERMISSION_GRANTED;
        } catch (Exception e) { return false; }
    }

    public static void requestCameraPermission() {
        final EguiCrActivity a = instance;
        if (a == null) return;
        a.runOnUiThread(new Runnable() {
            @Override public void run() {
                try {
                    if (!hasCameraPermission())
                        a.requestPermissions(
                            new String[]{android.Manifest.permission.CAMERA}, 1003);
                } catch (Exception e) { /* activity not attached */ }
            }
        });
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

    // System-port results (same queue discipline as the IME methods).
    native static void nativeSafResult(int seq, int ok, String uri);
    native static void nativeMsgboxResult(int value);
    native static void nativeClipboardChanged(String text);
}
