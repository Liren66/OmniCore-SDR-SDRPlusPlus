// OmniCore SDR source for SDR++ (AD9361 + Zynq + CH32H417 USB 3 bridge), through OmniCore Host (OCH), the radio's
// own driver library (omnicore-host submodule, OCH ABI 1).
//
// One receive input (RX1 or RX2) at up to 61.44 MSPS, 12-bit samples as normalised float I/Q. Frequency, gain,
// gain mode and analog bandwidth change while streaming (since OCH 0.4.7 a change of frequency or gain alone does not
// pause the stream); the input and the sample rate are chosen while stopped. The AD9361's RX DC and IQ tracking
// and its RX RSSI (relative dB, read twice a second while receiving) are shown in the menu.
#include <utils/flog.h>
#include <module.h>
#include <gui/gui.h>
#include <signal_path/signal_path.h>
#include <core.h>
#include <gui/style.h>
#include <gui/smgui.h>
#include <config.h>
#include <utils/optionlist.h>
#include <omnicore/och.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <mutex>
#include <thread>

#ifdef __ANDROID__
#include <android_backend.h>
// Added to the Android build of OCH (android/omnicore-host-android.patch): opens the radio from the USB file
// descriptor Android hands the app after the user allowed access.
extern "C" OCH_API int och_open_android_fd(int fd, const char* serial, och_device** out);
#endif

#define CONCAT(a, b) ((std::string(a) + b).c_str())

SDRPP_MOD_INFO{
    /* Name:            */ "omnicore_source",
    /* Description:     */ "OmniCore SDR source module for SDR++",
    /* Author:          */ "OmniCore SDR",
    /* Version:         */ 0, 1, 0,
    /* Max instances    */ 1
};

ConfigManager config;

namespace {
    constexpr double MIN_FREQ = 70e6, MAX_FREQ = 6e9;   // what OCH accepts (the AD9361 in its AD9364 range)
    constexpr double MAX_TX_ATTEN = 89.75;              // TX is not used here: both outputs at least power
    constexpr double USB2_RATE = 14e6;                  // one 12-bit channel over USB 2.0 High-Speed without loss
    constexpr uint32_t RECV_TIMEOUT_MS = 200;

    // The highest manual RX gain of the AD9361's gain tables at f; OCH refuses more
    float maxRxGain(double f) { return f <= 1.3e9 ? 73.0f : f <= 4e9 ? 71.0f : 62.0f; }

    std::string ochError(int code) {
        const char* e = och_last_error();
        std::string s = (e && *e) ? std::string(e) : std::string("OCH error");
        return s + " (" + std::to_string(code) + ")";
    }

    std::string trimmed(const char* s, size_t n) {
        size_t len = strnlen(s, n);
        return std::string(s, len);
    }

    // Exact labels: 61.44MHz, 30.72MHz, 2.5MHz, 200KHz (no rounding)
    std::string scaled(double hz) {
        char buf[64];
        if (hz >= 1e6) { snprintf(buf, sizeof(buf), "%.6f", hz / 1e6); }
        else { snprintf(buf, sizeof(buf), "%.3f", hz / 1e3); }
        std::string s = buf;
        s.erase(s.find_last_not_of('0') + 1);
        if (s.back() == '.') { s.pop_back(); }
        return s + (hz >= 1e6 ? "MHz" : "KHz");
    }
}

class OmniCoreSourceModule : public ModuleManager::Instance {
public:
    OmniCoreSourceModule(std::string name) {
        this->name = name;

        // Sample rates: the AD9361 without its FIR runs from 2.084 MSPS (12x the rate >= 25 MHz) to 61.44 MSPS
        const double rates[] = { 2.5e6, 3e6, 4e6, 5e6, 6e6, 8e6, 10e6, 12e6, 14e6, 15e6, 16e6, 20e6,
                                 25e6, 30e6, 30.72e6, 40e6, 50e6, 56e6, 61.44e6 };
        for (double r : rates) { samplerates.define((int)r, scaled(r), r); }

        // Analog filter bandwidths (0 = automatic: 95 % of the sample rate)
        bandwidths.define(0, "Auto", 0);
        const double bws[] = { 0.2e6, 0.5e6, 1e6, 1.5e6, 2e6, 3e6, 4e6, 5e6, 6e6, 8e6, 10e6, 12e6, 15e6, 16e6,
                               20e6, 25e6, 28e6, 30e6, 35e6, 40e6, 45e6, 50e6, 56e6 };
        for (double b : bws) { bandwidths.define((int)b, scaled(b), b); }

        ports.define("rx1", "RX1", 1);
        ports.define("rx2", "RX2", 2);

        gainModes.define("manual", "Manual", 0);
        gainModes.define("fast_attack", "Fast Attack", 1);
        gainModes.define("slow_attack", "Slow Attack", 2);
        gainModes.define("hybrid", "Hybrid", 3);

        refresh();

        config.acquire();
        std::string confSerial = config.conf["device"];
        config.release();
        select(confSerial);

        handler.ctx = this;
        handler.selectHandler = menuSelected;
        handler.deselectHandler = menuDeselected;
        handler.menuHandler = menuHandler;
        handler.startHandler = start;
        handler.stopHandler = stop;
        handler.tuneHandler = tune;
        handler.stream = &stream;
        sigpath::sourceManager.registerSource("OmniCore SDR", &handler);
    }

    ~OmniCoreSourceModule() {
        stop(this);
        sigpath::sourceManager.unregisterSource("OmniCore SDR");
    }

    void postInit() {}

    void enable() { enabled = true; }

    void disable() { enabled = false; }

    bool isEnabled() { return enabled; }

private:
    void refresh() {
        devices.clear();
#ifndef __ANDROID__
        size_t count = 0;
        int rc = och_list(NULL, 0, &count);
        if (rc != OCH_OK && rc != OCH_BUFFER_SMALL) {
            flog::error("OmniCore: cannot list radios: {}", ochError(rc));
            return;
        }
        if (!count) { return; }
        std::vector<och_device_info> list(count);
        for (auto& i : list) { i = {}; i.struct_size = sizeof(i); }
        rc = och_list(list.data(), list.size(), &count);
        if (rc != OCH_OK) {
            flog::error("OmniCore: cannot list radios: {}", ochError(rc));
            return;
        }
        list.resize(std::min(count, list.size()));
        for (const auto& i : list) {
            std::string serial = trimmed(i.serial, sizeof(i.serial));
            std::string model = trimmed(i.name, sizeof(i.name));
            if (model.empty()) { model = "OmniCore SDR"; }
            std::string label = model + " [" + serial + "]";
            if (devices.keyExists(serial) || devices.nameExists(label)) { continue; }
            devices.define(serial, label, serial);
        }
#else
        int vid, pid;
        devFd = backend::getDeviceFD(vid, pid, backend::OMNICORE_VIDPIDS);
        if (devFd < 0) { return; }
        devices.define("android", "OmniCore SDR (USB)", "android");
#endif
        flog::info("OmniCore: {} radio(s) found", devices.size());
    }

    void select(const std::string& serial) {
        if (devices.empty()) {
            selectedSerial.clear();
            return;
        }
        if (!devices.keyExists(serial)) {
            select(devices.key(0));
            return;
        }
        selectedSerial = serial;
        devId = devices.keyId(serial);

        // Defaults
        samplerate = 4000000;
        bandwidth = 0;
        portId = 0;
        gmId = 0;
        gain = 40;
        dcCorrection = true;
        iqCorrection = true;
        showRssi = true;

        config.acquire();
        json& d = config.conf["devices"][serial];
        if (d.contains("samplerate")) { samplerate = d["samplerate"]; }
        if (d.contains("bandwidth")) { bandwidth = d["bandwidth"]; }
        if (d.contains("port")) {
            std::string p = d["port"];
            if (ports.keyExists(p)) { portId = ports.keyId(p); }
        }
        if (d.contains("gainMode")) {
            std::string gm = d["gainMode"];
            if (gainModes.keyExists(gm)) { gmId = gainModes.keyId(gm); }
        }
        if (d.contains("gain")) { gain = std::clamp<float>(d["gain"], 0.0f, 73.0f); }
        if (d.contains("dcCorrection")) { dcCorrection = d["dcCorrection"]; }
        if (d.contains("iqCorrection")) { iqCorrection = d["iqCorrection"]; }
        if (d.contains("rssi")) { showRssi = d["rssi"]; }
        config.release();

        if (samplerates.keyExists(samplerate)) { srId = samplerates.keyId(samplerate); }
        else {
            srId = samplerates.keyId(4000000);
            samplerate = samplerates.value(srId);
        }
        if (bandwidths.keyExists(bandwidth)) { bwId = bandwidths.keyId(bandwidth); }
        else {
            bwId = 0;
            bandwidth = 0;
        }
    }

    template <typename T>
    void saveSetting(const char* key, const T& value) {
        if (selectedSerial.empty()) { return; }
        config.acquire();
        config.conf["devices"][selectedSerial][key] = value;
        config.release(true);
    }

    uint32_t bandwidthHz() const {
        double bw = bandwidth > 0 ? bandwidth : samplerate * 0.95;
        return (uint32_t)std::llround(std::clamp(bw, 0.2e6, 56e6));
    }

    // The receive part of the configuration from the menu's values (devMtx)
    void fillConfig(och_config& c) {
        c.sample_rate = (uint32_t)samplerate;
        c.rx_mask = (uint32_t)ports.value(portId);
        c.tx_mask = 0;
        double f = std::clamp(freq, MIN_FREQ, MAX_FREQ);
        c.rx_frequency = (uint64_t)std::llround(f);
        c.rx_bandwidth = bandwidthHz();
        c.rx_agc = (uint32_t)gainModes.value(gmId);
        float g = std::clamp<float>(std::round(gain), 0.0f, maxRxGain(f));
        c.rx_gain[0] = c.rx_gain[1] = g;
        c.tx_attenuation[0] = c.tx_attenuation[1] = MAX_TX_ATTEN;
    }

    // Applies the menu's values to the open radio (devMtx held). OCH keeps the stream running for frequency and
    // gain, and pauses / resumes it itself for the rest.
    bool applyConfig() {
        if (!dev) { return false; }
        och_config c = cfg;
        fillConfig(c);
        int rc = och_configure(dev, &c);
        if (rc != OCH_OK) {
            flog::error("OmniCore: configuration refused: {}", ochError(rc));
            return false;
        }
        cfg = c;
        return true;
    }

    // The AD9361's RX DC / IQ tracking: only a change is sent (devMtx held)
    void applyCorrections() {
        if (!dev) { return; }
        och_rx_correction_config cur = {};
        cur.struct_size = sizeof(cur);
        int rc = och_get_rx_correction(dev, &cur);
        if (rc == OCH_UNSUPPORTED) {
            correctionSupported = false;
            return;
        }
        correctionSupported = true;
        if (rc != OCH_OK) {
            flog::warn("OmniCore: cannot read the RX correction: {}", ochError(rc));
            return;
        }
        if ((bool)cur.dc_enabled != dcCorrection) {
            rc = och_set_rx_dc_correction(dev, dcCorrection);
            if (rc != OCH_OK) { flog::warn("OmniCore: RX DC correction not set: {}", ochError(rc)); }
        }
        if ((bool)cur.iq_enabled != iqCorrection) {
            rc = och_set_rx_iq_correction(dev, iqCorrection);
            if (rc != OCH_OK) { flog::warn("OmniCore: RX IQ correction not set: {}", ochError(rc)); }
        }
    }

    static void menuSelected(void* ctx) {
        OmniCoreSourceModule* _this = (OmniCoreSourceModule*)ctx;
        core::setInputSampleRate(_this->samplerate);
        flog::info("OmniCoreSourceModule '{0}': Menu Select!", _this->name);
    }

    static void menuDeselected(void* ctx) {
        OmniCoreSourceModule* _this = (OmniCoreSourceModule*)ctx;
        flog::info("OmniCoreSourceModule '{0}': Menu Deselect!", _this->name);
    }

    static void start(void* ctx) {
        OmniCoreSourceModule* _this = (OmniCoreSourceModule*)ctx;
        if (_this->running) { return; }
        if (_this->selectedSerial.empty()) {
            flog::error("OmniCore: no radio selected");
            return;
        }

        std::lock_guard<std::mutex> lck(_this->devMtx);
        int rc;
#ifndef __ANDROID__
        rc = och_open(_this->selectedSerial.c_str(), &_this->dev);
#else
        rc = och_open_android_fd(_this->devFd, "android", &_this->dev);
#endif
        if (rc != OCH_OK || !_this->dev) {
            _this->dev = NULL;
            flog::error("OmniCore: cannot open radio {}: {}{}", _this->selectedSerial, ochError(rc),
                        rc == OCH_BUSY ? " (another program has it open)" : "");
            return;
        }

        _this->info = {};
        _this->info.struct_size = sizeof(_this->info);
        if (och_get_info(_this->dev, &_this->info) == OCH_OK) {
            flog::info("OmniCore: opened {}, firmware {}, USB {} Mbit/s, OCH {}", trimmed(_this->info.serial, sizeof(_this->info.serial)),
                       trimmed(_this->info.firmware, sizeof(_this->info.firmware)), _this->info.usb_speed_mbps, och_version());
        }

        och_default_config(&_this->cfg);
        _this->applyCorrections();
        if (!_this->applyConfig()) {
            och_close(_this->dev);
            _this->dev = NULL;
            return;
        }

        // OCH may apply the nearest rate its clocks can make
        och_config applied = {};
        applied.struct_size = sizeof(applied);
        if (och_get_config(_this->dev, &applied) == OCH_OK && applied.sample_rate && applied.sample_rate != (uint32_t)_this->samplerate) {
            flog::info("OmniCore: sample rate {} applied as {}", _this->samplerate, applied.sample_rate);
        }

        if (och_set_rx_rssi_enabled(_this->dev, _this->showRssi) == OCH_UNSUPPORTED) {
            // older SDKs always report it
        }

        och_stream_args args;
        och_default_stream_args(&args, OCH_RX);
        args.format = OCH_FC32;
        rc = och_create_stream(_this->dev, &args, &_this->rx);
        if (rc != OCH_OK || !_this->rx) {
            flog::error("OmniCore: cannot create the receive stream: {}", ochError(rc));
            _this->rx = NULL;
            och_close(_this->dev);
            _this->dev = NULL;
            return;
        }
        rc = och_start(_this->rx);
        if (rc != OCH_OK) {
            flog::error("OmniCore: cannot start the receive stream: {}", ochError(rc));
            och_destroy_stream(_this->rx);
            _this->rx = NULL;
            och_close(_this->dev);
            _this->dev = NULL;
            return;
        }

        _this->hostOverflows = 0;
        _this->deviceOverflows = 0;
        _this->rssiValid = false;
        _this->running = true;
        _this->workerThread = std::thread(&OmniCoreSourceModule::worker, _this);
        flog::info("OmniCoreSourceModule '{0}': Start!", _this->name);
    }

    static void stop(void* ctx) {
        OmniCoreSourceModule* _this = (OmniCoreSourceModule*)ctx;
        if (!_this->running) { return; }
        _this->running = false;
        _this->stream.stopWriter();
        if (_this->workerThread.joinable()) { _this->workerThread.join(); }
        _this->stream.clearWriteStop();

        std::lock_guard<std::mutex> lck(_this->devMtx);
        if (_this->rx) {
            och_stop(_this->rx, 1000);
            int rc = och_destroy_stream(_this->rx);
            if (rc != OCH_OK && rc != OCH_IO) { flog::error("OmniCore: cannot destroy the receive stream: {}", ochError(rc)); }
            _this->rx = NULL;
        }
        if (_this->dev) {
            och_close(_this->dev);
            _this->dev = NULL;
        }
        flog::info("OmniCoreSourceModule '{0}': Stop!", _this->name);
    }

    static void tune(double freq, void* ctx) {
        OmniCoreSourceModule* _this = (OmniCoreSourceModule*)ctx;
        _this->freq = freq;
        if (freq > 0 && (freq < MIN_FREQ || freq > MAX_FREQ)) {
            flog::warn("OmniCore: the AD9361 tunes 70 MHz to 6 GHz; {} Hz is clamped", freq);
        }
        if (_this->running) {
            std::lock_guard<std::mutex> lck(_this->devMtx);
            _this->applyConfig();
        }
        flog::info("OmniCoreSourceModule '{0}': Tune: {1}!", _this->name, freq);
    }

    void reconfigure() {
        if (!running) { return; }
        std::lock_guard<std::mutex> lck(devMtx);
        applyConfig();
    }

    static void menuHandler(void* ctx) {
        OmniCoreSourceModule* _this = (OmniCoreSourceModule*)ctx;

        if (_this->running) { SmGui::BeginDisabled(); }
        SmGui::FillWidth();
        SmGui::ForceSync();
        if (SmGui::Combo(CONCAT("##_omnicore_dev_sel_", _this->name), &_this->devId, _this->devices.txt)) {
            _this->select(_this->devices.key(_this->devId));
            core::setInputSampleRate(_this->samplerate);
            config.acquire();
            config.conf["device"] = _this->selectedSerial;
            config.release(true);
        }

        if (SmGui::Combo(CONCAT("##_omnicore_sr_sel_", _this->name), &_this->srId, _this->samplerates.txt)) {
            _this->samplerate = _this->samplerates.key(_this->srId);
            core::setInputSampleRate(_this->samplerate);
            _this->saveSetting("samplerate", _this->samplerate);
        }

        SmGui::SameLine();
        SmGui::FillWidth();
        SmGui::ForceSync();
        if (SmGui::Button(CONCAT("Refresh##_omnicore_refr_", _this->name))) {
            _this->refresh();
            _this->select(_this->selectedSerial);
            core::setInputSampleRate(_this->samplerate);
        }

        SmGui::LeftLabel("Input");
        SmGui::FillWidth();
        if (SmGui::Combo(CONCAT("##_omnicore_port_", _this->name), &_this->portId, _this->ports.txt)) {
            _this->saveSetting("port", _this->ports.key(_this->portId));
        }
        if (_this->running) { SmGui::EndDisabled(); }

        SmGui::LeftLabel("Bandwidth");
        SmGui::FillWidth();
        if (SmGui::Combo(CONCAT("##_omnicore_bw_", _this->name), &_this->bwId, _this->bandwidths.txt)) {
            _this->bandwidth = _this->bandwidths.key(_this->bwId);
            _this->reconfigure();
            _this->saveSetting("bandwidth", _this->bandwidth);
        }

        SmGui::LeftLabel("Gain Mode");
        SmGui::FillWidth();
        SmGui::ForceSync();
        if (SmGui::Combo(CONCAT("##_omnicore_gm_", _this->name), &_this->gmId, _this->gainModes.txt)) {
            _this->reconfigure();
            _this->saveSetting("gainMode", _this->gainModes.key(_this->gmId));
        }

        SmGui::LeftLabel("Gain");
        if (_this->gmId) { SmGui::BeginDisabled(); }
        SmGui::FillWidth();
        if (SmGui::SliderFloatWithSteps(CONCAT("##_omnicore_gain_", _this->name), &_this->gain, 0.0f, 73.0f, 1.0f, SmGui::FMT_STR_FLOAT_DB_NO_DECIMAL)) {
            _this->reconfigure();
            _this->saveSetting("gain", _this->gain);
        }
        if (_this->gmId) { SmGui::EndDisabled(); }

        if (SmGui::Checkbox(CONCAT("DC Correction##_omnicore_dc_", _this->name), &_this->dcCorrection)) {
            if (_this->running) {
                std::lock_guard<std::mutex> lck(_this->devMtx);
                _this->applyCorrections();
            }
            _this->saveSetting("dcCorrection", _this->dcCorrection);
        }
        SmGui::SameLine();
        if (SmGui::Checkbox(CONCAT("IQ Correction##_omnicore_iq_", _this->name), &_this->iqCorrection)) {
            if (_this->running) {
                std::lock_guard<std::mutex> lck(_this->devMtx);
                _this->applyCorrections();
            }
            _this->saveSetting("iqCorrection", _this->iqCorrection);
        }

        if (SmGui::Checkbox(CONCAT("Show RSSI##_omnicore_rssi_", _this->name), &_this->showRssi)) {
            if (_this->running) {
                std::lock_guard<std::mutex> lck(_this->devMtx);
                if (_this->dev) { och_set_rx_rssi_enabled(_this->dev, _this->showRssi); }
            }
            _this->saveSetting("rssi", _this->showRssi);
        }

        // Status while receiving
        if (_this->running) {
            char buf[256];
            if (_this->showRssi) {
                if (_this->rssiValid) { snprintf(buf, sizeof(buf), "RSSI: %.1f dB (relative)", _this->rssiDb.load()); }
                else { snprintf(buf, sizeof(buf), "RSSI: --"); }
                SmGui::Text(buf);
            }
            snprintf(buf, sizeof(buf), "USB %s, overflows %llu host / %llu radio",
                     _this->info.usb_speed_mbps >= 5000 ? "3" : (_this->info.usb_speed_mbps == 480 ? "2.0" : "?"),
                     (unsigned long long)_this->hostOverflows.load(), (unsigned long long)_this->deviceOverflows.load());
            SmGui::Text(buf);
            if (_this->info.usb_speed_mbps == 480 && _this->samplerate > USB2_RATE) {
                SmGui::TextColored(ImVec4(1.0f, 0.6f, 0.0f, 1.0f), "USB 2.0 carries ~14 MSPS: use USB 3 or a lower rate");
            }
            if (!_this->correctionSupported) {
                SmGui::Text("Firmware has no RX DC/IQ correction control");
            }
        }
    }

    void worker() {
        int blockSize = std::clamp<int>(samplerate / 200, 4096, STREAM_BUFFER_SIZE);
        auto nextRssi = std::chrono::steady_clock::now();
        while (running) {
            size_t got = 0;
            och_metadata md = {};
            md.struct_size = sizeof(md);
            int rc = och_recv(rx, stream.writeBuf, blockSize, &got, &md, RECV_TIMEOUT_MS);
            if (rc == OCH_OK) {
                if (md.flags & OCH_META_HOST_OVERFLOW) { hostOverflows++; }
                if (md.flags & OCH_META_DEVICE_OVERFLOW) { deviceOverflows++; }
                if (got && !stream.swap((int)got)) { break; }
            }
            else if (rc != OCH_TIMEOUT) {
                if (running) { flog::error("OmniCore: the receive stream ended: {}", ochError(rc)); }
                break;
            }

            // RSSI twice a second; never wait for a control call in progress
            auto now = std::chrono::steady_clock::now();
            if (showRssi && now >= nextRssi) {
                nextRssi = now + std::chrono::milliseconds(500);
                std::unique_lock<std::mutex> lck(devMtx, std::try_to_lock);
                if (lck.owns_lock() && dev) {
                    och_rx_rssi r = {};
                    r.struct_size = sizeof(r);
                    if (och_get_rx_rssi(dev, &r) == OCH_OK) {
                        int ch = ports.value(portId) == 2 ? 1 : 0;
                        rssiValid = r.enabled && r.valid[ch];
                        rssiDb = r.rssi_db[ch];
                    }
                    else {
                        rssiValid = false;
                    }
                }
            }
        }
    }

    std::string name;
    bool enabled = true;
    dsp::stream<dsp::complex_t> stream;
    SourceManager::SourceHandler handler;
    std::atomic<bool> running = false;
    std::thread workerThread;

    std::mutex devMtx;   // control calls on dev
    och_device* dev = NULL;
    och_stream* rx = NULL;
    och_config cfg = {};
    och_device_info info = {};

    std::string selectedSerial;
    double freq = 100e6;
    int samplerate = 4000000;
    int bandwidth = 0;
    float gain = 40;
    bool dcCorrection = true;
    bool iqCorrection = true;
    bool correctionSupported = true;
    bool showRssi = true;

    std::atomic<uint64_t> hostOverflows = 0, deviceOverflows = 0;
    std::atomic<bool> rssiValid = false;
    std::atomic<double> rssiDb = 0;

    int devId = 0;
    int srId = 0;
    int bwId = 0;
    int portId = 0;
    int gmId = 0;

#ifdef __ANDROID__
    int devFd = -1;
#endif

    OptionList<std::string, std::string> devices;
    OptionList<int, double> samplerates;
    OptionList<int, double> bandwidths;
    OptionList<std::string, int> ports;
    OptionList<std::string, int> gainModes;
};

MOD_EXPORT void _INIT_() {
    json def = json({});
    def["devices"] = json({});
    def["device"] = "";
    config.setPath(core::args["root"].s() + "/omnicore_source_config.json");
    config.load(def);
    config.enableAutoSave();
}

MOD_EXPORT ModuleManager::Instance* _CREATE_INSTANCE_(std::string name) {
    return new OmniCoreSourceModule(name);
}

MOD_EXPORT void _DELETE_INSTANCE_(ModuleManager::Instance* instance) {
    delete (OmniCoreSourceModule*)instance;
}

MOD_EXPORT void _END_() {
    config.disableAutoSave();
    config.save();
}
