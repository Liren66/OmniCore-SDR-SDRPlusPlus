package org.sdrpp.sdrpp;

import android.app.NativeActivity;
import android.app.AlertDialog;
import android.app.PendingIntent;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.DialogInterface;
import android.content.pm.PackageManager;
import android.hardware.usb.*;
import android.Manifest;
import android.os.Bundle;
import android.view.View;
import android.view.KeyEvent;
import android.view.inputmethod.InputMethodManager;
import android.util.Log;
import android.content.res.AssetManager;

import androidx.core.app.ActivityCompat;

import androidx.core.content.PermissionChecker;

import java.util.concurrent.LinkedBlockingQueue;
import java.io.*;

private const val ACTION_USB_PERMISSION = "org.sdrpp.sdrpp.USB_PERMISSION";

// OmniCore SDR (CH32H417 USB bridge)
private const val OMNICORE_VID = 0x1a86;
private const val OMNICORE_PID = 0x5537;

private val usbReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (ACTION_USB_PERMISSION == intent.action) {
            synchronized(this) {
                var _this = context as MainActivity;
                val dev : UsbDevice? = intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                if (dev != null && intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                    _this.useDevice(dev);
                }

                // Hide again the system bars
                _this.hideSystemBars();
            }
        }
    }
}

class MainActivity : NativeActivity() {
    private val TAG : String = "SDR++";
    public var usbManager : UsbManager? = null;
    public var SDR_device : UsbDevice? = null;
    public var SDR_conn : UsbDeviceConnection? = null;
    public var SDR_VID : Int = -1;
    public var SDR_PID : Int = -1;
    public var SDR_FD : Int = -1;

    fun checkAndAsk(permission: String) {
        if (PermissionChecker.checkSelfPermission(this, permission) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, arrayOf(permission), 1);
        }
    }

    public fun hideSystemBars() {
        val decorView = getWindow().getDecorView();
        val uiOptions = View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY;
        decorView.setSystemUiVisibility(uiOptions);
    }

    public override fun onCreate(savedInstanceState: Bundle?) {
        // Hide bars
        hideSystemBars();

        // Ask for required permissions, without these the app cannot run.
        checkAndAsk(Manifest.permission.WRITE_EXTERNAL_STORAGE);
        checkAndAsk(Manifest.permission.READ_EXTERNAL_STORAGE);

        // TODO: Have the main code wait until these two permissions are available

        // Register events (the receiver stays registered: the radio may be plugged in later)
        usbManager = getSystemService(Context.USB_SERVICE) as UsbManager;
        val filter = IntentFilter(ACTION_USB_PERMISSION)
        registerReceiver(usbReceiver, filter)

        // Get permission for the radios connected now (the OmniCore SDR first)
        requestRadios(intent);

        // Ask for internet permission
        checkAndAsk(Manifest.permission.INTERNET);

        super.onCreate(savedInstanceState)
    }

    // The app (singleTask) was asked to open a radio plugged in while it runs
    public override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        requestRadios(intent);
    }

    // Opens the device and publishes its descriptor to the native code (SDR_FD / SDR_VID / SDR_PID)
    public fun useDevice(dev: UsbDevice) {
        if (SDR_device != null && SDR_device!!.getDeviceName() == dev.getDeviceName() && SDR_FD >= 0) { return; }
        val conn = usbManager!!.openDevice(dev) ?: return;
        SDR_conn?.close();
        SDR_device = dev;
        SDR_conn = conn;
        SDR_VID = dev.getVendorId();
        SDR_PID = dev.getProductId();
        SDR_FD = conn.getFileDescriptor();
        Log.i(TAG, "USB device " + dev.getDeviceName() + " open, fd " + SDR_FD);
    }

    fun requestRadios(intent: Intent?) {
        val permissionIntent = PendingIntent.getBroadcast(this, 0, Intent(ACTION_USB_PERMISSION).setPackage(packageName), PendingIntent.FLAG_IMMUTABLE)
        val devs = ArrayList(usbManager!!.getDeviceList().values);
        // Launched by plugging in a radio: Android already granted access to it
        val attached : UsbDevice? = intent?.getParcelableExtra(UsbManager.EXTRA_DEVICE);
        if (attached != null && usbManager!!.hasPermission(attached)) { useDevice(attached); }
        devs.sortBy { if (it.getVendorId() == OMNICORE_VID && it.getProductId() == OMNICORE_PID) 0 else 1 }
        for (dev in devs) {
            if (usbManager!!.hasPermission(dev)) { useDevice(dev); break; }
            usbManager!!.requestPermission(dev, permissionIntent);
            break;
        }
    }

    public override fun onResume() {
        // Hide bars again
        hideSystemBars();
        super.onResume();
    }

    fun showSoftInput() {
        val inputMethodManager = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager;
        inputMethodManager.showSoftInput(window.decorView, 0);
    }

    fun hideSoftInput() {
        val inputMethodManager = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager;
        inputMethodManager.hideSoftInputFromWindow(window.decorView.windowToken, 0);
        hideSystemBars();
    }

    // Queue for the Unicode characters to be polled from native code (via pollUnicodeChar())
    private var unicodeCharacterQueue: LinkedBlockingQueue<Int> = LinkedBlockingQueue()

    // We assume dispatchKeyEvent() of the NativeActivity is actually called for every
    // KeyEvent and not consumed by any View before it reaches here
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            unicodeCharacterQueue.offer(event.getUnicodeChar(event.metaState))
        }
        return super.dispatchKeyEvent(event)
    }

    fun pollUnicodeChar(): Int {
        return unicodeCharacterQueue.poll() ?: 0
    }

    public fun createIfDoesntExist(path: String) {
        // This is a directory, create it in the filesystem
        var folder = File(path);
        var success = true;
        if (!folder.exists()) {
            success = folder.mkdirs();
        }
        if (!success) {
            Log.e(TAG, "Could not create folder with path " + path);
        }
    }

    public fun extractDir(aman: AssetManager, local: String, rsrc: String): Int {
        val flist = aman.list(rsrc) ?: arrayOf<String>();
        var ecount = 0;
        for (fp in flist) {
            val lpath = local + "/" + fp;
            val rpath = rsrc + "/" + fp;

            Log.w(TAG, "Extracting '" + rpath + "' to '" + lpath + "'");

            // Create local path if non-existent
            createIfDoesntExist(local);
            
            // Create if directory
            val ext = extractDir(aman, lpath, rpath);

            // Extract if file
            if (ext == 0) {
                // This is a file, extract it
                val _os = FileOutputStream(lpath);
                val _is = aman.open(rpath);
                val ilen = _is.available();
                var fbuf = ByteArray(ilen);
                _is.read(fbuf, 0, ilen);
                _os.write(fbuf);
                _os.close();
                _is.close();
            }

            ecount++;
        }
        return ecount;
    }

    public fun getAppDir(): String {
        val fdir = getFilesDir().getAbsolutePath();

        // Extract all resources to the app directory
        val aman = getAssets();
        extractDir(aman, fdir + "/res", "res");
        createIfDoesntExist(fdir + "/modules");

        return fdir;
    }
}
