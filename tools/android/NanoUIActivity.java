package dev.nanoui.android;

import android.app.NativeActivity;
import android.content.ActivityNotFoundException;
import android.content.ContentResolver;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;
import android.webkit.MimeTypeMap;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.UUID;

/**
 * The NativeActivity nanoui's file picker needs: Android answers a picker in
 * the activity's result, which NativeActivity drops. Use it as the app's
 * activity, or extend it; a subclass that overrides onActivityResult or
 * onDestroy calls super.
 *
 * <p>Request codes: nanoui reserves 0x6e00 to 0x6eff (28160 to 28415) for its
 * own activity results; a subclass uses codes outside that range. Results for
 * any other code pass through to super.onActivityResult untouched, so a
 * subclass may call super first and then handle its own codes.
 *
 * <p>`dialog.open` asks on the app's thread (`nanouiOpenDocument`) and waits.
 * Java's thread shows the system's document picker. The chosen document is
 * copied on a thread of its own, at most `limit` bytes, into a folder of its
 * own in the app's cache, and the app's thread is woken to take the answer
 * (`nanouiTakeDocument`). A copy taken belongs to the app, which deletes it
 * and its folder; copies an earlier process left are removed by the next
 * pick, and Android may clear the cache when storage runs low.
 */
public class NanoUIActivity extends NativeActivity {
    /** In nanoui's reserved range, 0x6e00 to 0x6eff. */
    private static final int OPEN_DOCUMENT = 0x6e75;
    private static final String STAGING = "nanoui-documents";
    private static final String PROCESS = UUID.randomUUID().toString();
    private static final int NAME_BYTES = 240;
    /** Answers that are not a path (a path starts with '/'). */
    private static final String CANCELED = "";
    private static final String TOO_LARGE = ":too_large";
    private static final String UNSUPPORTED = ":unsupported";
    private static final String UNAVAILABLE = ":unavailable";
    private static final String FAILED = ":failed";

    /** Registered by nanoui: wakes the app's thread to take the answer. */
    private static native void nanouiDocumentAnswered();

    // Guarded by this.
    private boolean picking;
    private boolean awaiting;
    private boolean destroyed;
    private String answer;
    private String[] extensions = new String[0];
    private long limit;

    /** On the app's thread: shows the picker; false if one is already open. */
    public final synchronized boolean nanouiOpenDocument(String[] allowed, long maxBytes) {
        if (picking || destroyed || maxBytes <= 0) return false;
        picking = true;
        answer = null;
        extensions = allowed == null ? new String[0] : allowed.clone();
        limit = maxBytes;
        runOnUiThread(this::startPicker);
        return true;
    }

    /** On the app's thread: the answer, once; null while the user chooses. */
    public final synchronized String nanouiTakeDocument() {
        if (answer == null) return null;
        String taken = answer;
        answer = null;
        picking = false;
        return taken;
    }

    private void startPicker() {
        String[] allowed;
        synchronized (this) {
            if (destroyed || isFinishing()) {
                answer(UNAVAILABLE);
                return;
            }
            awaiting = true;
            allowed = extensions;
        }
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE);
        String[] types = mimeTypes(allowed);
        intent.setType(types.length == 1 ? types[0] : "*/*");
        if (types.length > 1) intent.putExtra(Intent.EXTRA_MIME_TYPES, types);
        try {
            startActivityForResult(intent, OPEN_DOCUMENT);
        } catch (ActivityNotFoundException | SecurityException failure) {
            synchronized (this) {
                awaiting = false;
            }
            answer(UNAVAILABLE);
        }
    }

    /** The types the extensions name; every type when one is unknown. */
    private static String[] mimeTypes(String[] allowed) {
        if (allowed.length == 0) return new String[]{"*/*"};
        String[] types = new String[allowed.length];
        MimeTypeMap map = MimeTypeMap.getSingleton();
        for (int i = 0; i < allowed.length; i++) {
            types[i] = map.getMimeTypeFromExtension(allowed[i].toLowerCase(Locale.ROOT));
            if (types[i] == null) return new String[]{"*/*"};
        }
        return types;
    }

    @Override protected void onActivityResult(int request, int status, Intent data) {
        if (request != OPEN_DOCUMENT) {
            super.onActivityResult(request, status, data);
            return;
        }
        final String[] allowed;
        final long max;
        synchronized (this) {
            if (!awaiting || destroyed) return;
            awaiting = false;
            allowed = extensions;
            max = limit;
        }
        if (status != RESULT_OK) {
            answer(CANCELED);
            return;
        }
        final Uri uri = data == null ? null : data.getData();
        if (uri == null || !ContentResolver.SCHEME_CONTENT.equals(uri.getScheme())) {
            answer(FAILED);
            return;
        }
        final ContentResolver resolver = getApplicationContext().getContentResolver();
        final File cache = getCacheDir();
        // A provider's reads can block (a network or streaming provider).
        new Thread(() -> answer(stage(resolver, cache, uri, allowed, max)), "nanoui document copy").start();
    }

    private static String stage(ContentResolver resolver, File cache, Uri uri, String[] allowed, long max) {
        File folder = null;
        boolean complete = false;
        try {
            String name = displayName(resolver, uri);
            if (!allowedName(name, allowed)) return UNSUPPORTED;
            File root = new File(cache, STAGING);
            clearEarlierProcesses(root);
            File process = new File(root, PROCESS);
            if (!process.isDirectory() && !process.mkdirs()) return FAILED;
            folder = new File(process, UUID.randomUUID().toString());
            if (!folder.mkdir()) return FAILED;
            File output = new File(folder, name);
            try (InputStream input = resolver.openInputStream(uri);
                 FileOutputStream writer = new FileOutputStream(output)) {
                if (input == null) return FAILED;
                byte[] buffer = new byte[64 * 1024];
                long total = 0;
                for (int n; (n = input.read(buffer)) != -1; ) {
                    if (n > max - total) return TOO_LARGE;
                    writer.write(buffer, 0, n);
                    total += n;
                }
                writer.getFD().sync();
            }
            complete = true;
            return output.getAbsolutePath();
        } catch (IOException | RuntimeException failure) {
            return FAILED;
        } finally {
            if (!complete && folder != null) delete(folder);
        }
    }

    /** The provider's name for the document, or "document" if it has none usable. */
    private static String displayName(ContentResolver resolver, Uri uri) {
        String name = null;
        try (Cursor row = resolver.query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (row != null && row.moveToFirst()) name = row.getString(0);
        } catch (RuntimeException ignored) {
            // The name is optional metadata.
        }
        if (name == null || name.isEmpty() || name.equals(".") || name.equals("..")
                || name.getBytes(StandardCharsets.UTF_8).length > NAME_BYTES
                || name.indexOf('/') >= 0 || name.indexOf('\\') >= 0) return "document";
        for (int i = 0; i < name.length(); i++) {
            if (Character.isISOControl(name.charAt(i))) return "document";
        }
        return name;
    }

    private static boolean allowedName(String name, String[] allowed) {
        if (allowed.length == 0) return true;
        int dot = name.lastIndexOf('.');
        if (dot <= 0) return false;
        String extension = name.substring(dot + 1);
        for (String candidate : allowed) {
            if (candidate.equalsIgnoreCase(extension)) return true;
        }
        return false;
    }

    private static void clearEarlierProcesses(File root) {
        File[] processes = root.listFiles();
        if (processes == null) return;
        for (File process : processes) {
            if (!process.getName().equals(PROCESS)) delete(process);
        }
    }

    private static void delete(File file) {
        File[] children = file.listFiles();
        if (children != null) for (File child : children) delete(child);
        file.delete();
    }

    /** A copied document's folder goes with it. */
    private static void discard(String value) {
        if (value != null && value.startsWith("/")) delete(new File(value).getParentFile());
    }

    private void answer(String value) {
        synchronized (this) {
            if (destroyed) {
                discard(value);
                return;
            }
            answer = value;
        }
        try {
            nanouiDocumentAnswered();
        } catch (LinkageError unregistered) {
            // No native waiter registered: the answer is taken at the next look.
        }
    }

    @Override protected void onDestroy() {
        synchronized (this) {
            destroyed = true;
            awaiting = false;
            discard(answer);
            answer = null;
        }
        super.onDestroy();
    }
}
