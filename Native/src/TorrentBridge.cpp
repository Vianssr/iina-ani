#include "TorrentBridge.h"

#include <libtorrent/alert.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/bdecode.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/ip_filter.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/version.hpp>
#include <libtorrent/write_resume_data.hpp>

#include <algorithm>
#include <atomic>
#include <array>
#include <chrono>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <limits>
#include <set>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <system_error>
#include <CoreFoundation/CoreFoundation.h>
#include <cstdlib>
#include <limits.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <thread>
#include <utility>
#include <condition_variable>
#include <vector>

namespace lt = libtorrent;
namespace fs = std::filesystem;

struct tb_reader_request {
    bool complete = false;
    bool cancelled = false;
    tb_error_code code = TB_OK;
    uint32_t piece_offset = 0;
    uint32_t length = 0;
    uint8_t *buffer = nullptr;
};
struct tb_reader { tb_torrent_id torrent = 0; int file = -1; uint64_t active_request = 0; uint64_t last_completed_request = 0; std::set<uint64_t> cancelled_requests; std::shared_ptr<tb_reader_request> active; };
struct tb_session {
    std::mutex mutex;
    std::condition_variable readers_changed;
    std::unique_ptr<lt::session> native;
    std::map<tb_torrent_id, lt::torrent_handle> torrents;
    std::set<tb_torrent_id> unsafe_metadata;
    std::deque<tb_event> events;
    std::vector<lt::alert *> alert_buffer;
    std::vector<int64_t> progress_buffer;
    std::map<uint64_t, tb_reader> readers;
    std::map<std::pair<tb_torrent_id, int>, std::vector<std::shared_ptr<tb_reader_request>>> piece_waiters;
    tb_torrent_id next_id = 1;
    uint64_t next_reader_id = 1;
    uint32_t active_reads = 0;
    bool closing = false;
    bool public_network = false;
};

namespace {
void clear_error(tb_error *error) noexcept { if (error) { error->code = TB_OK; error->message[0] = '\0'; } }
tb_error_code fail(tb_error *error, tb_error_code code, const char *message) noexcept {
    if (error) { error->code = code; std::strncpy(error->message, message ? message : "native error", sizeof(error->message) - 1); error->message[sizeof(error->message) - 1] = '\0'; }
    return code;
}
tb_error_code exception_fail(tb_error *error) noexcept {
    try { throw; } catch (std::filesystem::filesystem_error const &e) { return fail(error, TB_ERROR_IO, e.what()); }
    catch (std::exception const &e) { return fail(error, TB_ERROR_INTERNAL, e.what()); } catch (...) { return fail(error, TB_ERROR_INTERNAL, "unknown native exception"); }
}
void copy_message(char (&dst)[256], std::string const &src) noexcept { std::strncpy(dst, src.c_str(), sizeof(dst)-1); dst[sizeof(dst)-1] = '\0'; }
void tagged_hash(char *out, char algorithm, char const *bytes, size_t count) noexcept {
    static constexpr char hex[] = "0123456789abcdef";
    out[0] = 'v'; out[1] = algorithm; out[2] = ':';
    for (size_t i = 0; i < count; ++i) {
        auto const byte = static_cast<unsigned char>(bytes[i]);
        out[3 + 2 * i] = hex[byte >> 4];
        out[4 + 2 * i] = hex[byte & 15];
    }
    out[3 + 2 * count] = '\0';
}
bool unsafe_component(std::string const &part) {
    return part.empty() || part == "." || part == ".." || part.find('/') != std::string::npos || part.find('\\') != std::string::npos || part.find('\0') != std::string::npos;
}
bool safe_relative(std::string const &path) {
    fs::path p(path);
    if (p.empty() || p.is_absolute() || p.has_root_name() || p.has_root_directory()) return false;
    for (auto const &component : p) if (unsafe_component(component.string())) return false;
    return true;
}
bool safe_bencoded_component(lt::string_view value) {
    return !unsafe_component(std::string(value.data(), value.size()));
}
bool validate_tree(lt::bdecode_node const &tree) {
    if (tree.type() != lt::bdecode_node::dict_t) return false;
    for (int i = 0; i < tree.dict_size(); ++i) {
        auto [key, value] = tree.dict_at(i);
        if (key.empty()) {
            if (value.type() != lt::bdecode_node::dict_t) return false;
            if (value.dict_find_string_value("attr").find("l") != lt::string_view::npos) return false;
            continue;
        }
        if (!safe_bencoded_component(key) || !validate_tree(value)) return false;
    }
    return true;
}
bool validate_info_node(lt::bdecode_node const &info) {
    if (info.type() != lt::bdecode_node::dict_t) return false;
    for (auto key : {lt::string_view("name"), lt::string_view("name.utf-8")}) {
        auto name = info.dict_find_string_value(key);
        if (!name.empty() && !safe_bencoded_component(name)) return false;
    }
    auto files = info.dict_find_list("files");
    if (files) for (int i = 0; i < files.list_size(); ++i) {
        auto file = files.list_at(i);
        if (file.dict_find_string_value("attr").find("l") != lt::string_view::npos) return false;
        for (auto key : {lt::string_view("path"), lt::string_view("path.utf-8")}) {
            auto parts = file.dict_find_list(key);
            if (parts) for (int j = 0; j < parts.list_size(); ++j)
                if (!safe_bencoded_component(parts.list_string_value_at(j))) return false;
        }
    }
    auto tree = info.dict_find_dict("file tree");
    return !tree || validate_tree(tree);
}
bool validate_torrent_bytes(lt::span<char const> bytes) {
    lt::error_code ec;
    auto root = lt::bdecode(bytes, ec);
    return !ec && root.type() == lt::bdecode_node::dict_t && validate_info_node(root.dict_find_dict("info"));
}
std::vector<char> read_attachment(char const *path) {
    std::error_code ec;
    if (!fs::is_regular_file(path, ec) || ec) return {};
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    auto const size = input.tellg();
    if (!input || size <= 0 || size > 10 * 1024 * 1024) return {};
    std::vector<char> bytes(static_cast<size_t>(size));
    input.seekg(0);
    if (!input.read(bytes.data(), static_cast<std::streamsize>(size))
        || input.peek() != std::char_traits<char>::eof()) return {};
    return bytes;
}
bool validate_original_torrent(char const *path) {
    auto const bytes = read_attachment(path);
    return !bytes.empty()
        && validate_torrent_bytes(lt::span<char const>(bytes.data(), bytes.size()));
}
bool validate_info_metadata(lt::torrent_info const &info) {
    auto bytes = info.metadata();
    int const size = info.metadata_size();
    return bytes && size > 0 && validate_info_node(lt::bdecode(lt::span<char const>(bytes.get(), size)));
}
bool safe_destination(fs::path const &root, lt::file_storage const &files) {
    std::error_code ec;
    fs::path trusted_root = fs::weakly_canonical(root, ec);
    if (ec) return false;
    for (int i = 0; i < files.num_files(); ++i) {
        auto const index = lt::file_index_t{i};
        std::string relative = files.file_path(index);
        if (!safe_relative(relative) || !files.symlink(index).empty()) return false;
        fs::path current = trusted_root;
        for (auto const &part : fs::path(relative)) {
            current /= part;
            auto status = fs::symlink_status(current, ec);
            if (ec == std::errc::no_such_file_or_directory) { ec.clear(); continue; }
            if (ec || fs::is_symlink(status)) return false;
        }
    }
    return true;
}
bool progress_is_validated(lt::torrent_handle const &handle) {
    auto const state = handle.status().state;
    return state != lt::torrent_status::checking_files && state != lt::torrent_status::checking_resume_data;
}
uint64_t verified_bytes(tb_session &owner, lt::torrent_handle const &handle) {
    auto info = handle.torrent_file();
    if (!info || !progress_is_validated(handle)) return 0;
    handle.file_progress(owner.progress_buffer, lt::torrent_handle::piece_granularity);
    uint64_t total = 0;
    auto const &files = info->layout();
    for (int i = 0; i < files.num_files(); ++i) {
        auto const index = lt::file_index_t{i};
        if (files.pad_file_at(index)) continue;
        auto const bytes = std::max<int64_t>(0, owner.progress_buffer[static_cast<size_t>(i)]);
        total += static_cast<uint64_t>(std::min<int64_t>(bytes, files.file_size(index)));
    }
    return total;
}
tb_torrent_id id_for_handle(tb_session const &owner, lt::torrent_handle const &handle) { for (auto const &item:owner.torrents) if (item.second==handle) return item.first; return 0; }
lt::torrent_handle *find_torrent(tb_session &owner, tb_torrent_id id) { auto it=owner.torrents.find(id); return it==owner.torrents.end()?nullptr:&it->second; }
void retire_piece_waiter(tb_session &owner, std::pair<tb_torrent_id, int> const &key, std::shared_ptr<tb_reader_request> const &request) {
    auto it = owner.piece_waiters.find(key);
    if (it == owner.piece_waiters.end()) return;
    auto &waiters = it->second;
    waiters.erase(std::remove(waiters.begin(), waiters.end(), request), waiters.end());
    if (waiters.empty()) {
        if (auto *handle = find_torrent(owner, key.first)) handle->reset_piece_deadline(lt::piece_index_t{key.second});
        owner.piece_waiters.erase(it);
    }
}
struct tb_reader_read_guard {
    tb_session &owner;
    std::unique_lock<std::mutex> &lock;
    uint64_t reader_id;
    uint64_t request_id;
    std::pair<tb_torrent_id, int> key;
    std::shared_ptr<tb_reader_request> request;
    bool active = true;
    void finish() noexcept {
        if (!active) return;
        try {
            if (!lock.owns_lock()) lock.lock();
            if (!request->complete) {
                request->complete = true;
                request->cancelled = true;
                request->code = TB_ERROR_CANCELLED;
                try { retire_piece_waiter(owner, key, request); } catch (...) {}
            }
            auto current = owner.readers.find(reader_id);
            if (current != owner.readers.end() && current->second.active == request) {
                current->second.active.reset();
                current->second.active_request = 0;
                current->second.last_completed_request = std::max(current->second.last_completed_request, request_id);
            }
            if (owner.active_reads) --owner.active_reads;
            owner.readers_changed.notify_all();
            active = false;
        } catch (...) { active = false; }
    }
    ~tb_reader_read_guard() { finish(); }
};
void dispatch_read_piece(tb_session &owner, lt::read_piece_alert const &alert) {
    auto const torrent_id = id_for_handle(owner, alert.handle);
    auto const key = std::make_pair(torrent_id, static_cast<int>(alert.piece));
    auto it = owner.piece_waiters.find(key);
    if (it == owner.piece_waiters.end()) return;
    auto waiters = std::move(it->second);
    owner.piece_waiters.erase(it);
    for (auto const &request : waiters) {
        if (!request || request->complete) continue;
        if (alert.error || !alert.buffer || alert.size < 0 || request->piece_offset > static_cast<uint32_t>(alert.size)
            || request->length > static_cast<uint32_t>(alert.size) - request->piece_offset) {
            request->code = TB_ERROR_TORRENT;
        } else {
            auto const *start = reinterpret_cast<uint8_t const *>(alert.buffer.get() + request->piece_offset);
            std::memcpy(request->buffer, start, request->length);
        }
        request->complete = true;
    }
    if (auto *handle = find_torrent(owner, torrent_id)) handle->reset_piece_deadline(alert.piece);
    owner.readers_changed.notify_all();
}
void enqueue_alert(tb_session &owner, lt::alert const *alert) {
    if (auto const *piece = lt::alert_cast<lt::read_piece_alert>(alert)) { dispatch_read_piece(owner, *piece); return; }
    tb_event event{}; bool emit=false;
    if (auto const *a=lt::alert_cast<lt::torrent_finished_alert>(alert)) { event.type=TB_EVENT_TORRENT_FINISHED; event.torrent_id=id_for_handle(owner,a->handle); emit=event.torrent_id!=0; }
    else if (auto const *a=lt::alert_cast<lt::torrent_error_alert>(alert)) { event.type=TB_EVENT_TORRENT_ERROR; event.torrent_id=id_for_handle(owner,a->handle); event.error_code=a->error.value()==ENOSPC?TB_ERROR_DISK_FULL:TB_ERROR_TORRENT; emit=event.torrent_id!=0; }
    else if (auto const *a=lt::alert_cast<lt::state_changed_alert>(alert)) { event.type=TB_EVENT_STATE_CHANGED; event.torrent_id=id_for_handle(owner,a->handle); emit=event.torrent_id!=0; }
    else if (auto const *a=lt::alert_cast<lt::peer_connect_alert>(alert)) { event.type=TB_EVENT_PEER_CONNECTED; event.torrent_id=id_for_handle(owner,a->handle); emit=event.torrent_id!=0; }
    else if (auto const *a=lt::alert_cast<lt::metadata_received_alert>(alert)) {
        event.torrent_id=id_for_handle(owner,a->handle);
        auto info=a->handle.torrent_file();
        if (event.torrent_id && (!info || !validate_info_metadata(*info))) {
            owner.unsafe_metadata.insert(event.torrent_id);
            event.type=TB_EVENT_TORRENT_ERROR; event.error_code=TB_ERROR_UNSAFE_PATH;
            copy_message(event.message,"torrent metadata contains unsafe paths");
            a->handle.pause(); emit=true;
        } else if (event.torrent_id) {
            event.type=TB_EVENT_METADATA_RECEIVED; emit=true;
            if (info->priv()) a->handle.set_flags(lt::torrent_flags::disable_dht|lt::torrent_flags::disable_lsd|lt::torrent_flags::disable_pex);
        }
    }
    else if (auto const *a=lt::alert_cast<lt::file_error_alert>(alert)) { event.type=TB_EVENT_TORRENT_ERROR; event.torrent_id=id_for_handle(owner,a->handle); event.error_code=a->error.value()==ENOSPC?TB_ERROR_DISK_FULL:TB_ERROR_TORRENT; emit=event.torrent_id!=0; }
    if (!emit) return;
    if (auto it=owner.torrents.find(event.torrent_id); it!=owner.torrents.end()) { auto st=it->second.status(); event.total_bytes=static_cast<uint64_t>(std::max<int64_t>(0,st.total_wanted)); event.verified_bytes=verified_bytes(owner,it->second); }
    owner.events.push_back(event);
}
void harvest_alerts(tb_session &owner) { owner.native->pop_alerts(&owner.alert_buffer); for (auto const *a:owner.alert_buffer) enqueue_alert(owner,a); owner.alert_buffer.clear(); }
tb_torrent_id insert_handle(tb_session &owner, lt::torrent_handle handle) { auto id=owner.next_id++; if (!id) id=owner.next_id++; owner.torrents.emplace(id,std::move(handle)); return id; }
bool stop_and_flush(tb_session &owner, lt::torrent_handle const &handle) {
    bool paused = static_cast<bool>(handle.status().flags & lt::torrent_flags::paused);
    bool const has_metadata = static_cast<bool>(handle.torrent_file());
    handle.pause();
    if (!has_metadata) {
        auto const deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
        while (!paused && std::chrono::steady_clock::now() < deadline) {
            owner.native->wait_for_alert(std::chrono::milliseconds(50));
            owner.native->pop_alerts(&owner.alert_buffer);
            for (auto const *alert : owner.alert_buffer) {
                auto const *paused_alert = lt::alert_cast<lt::torrent_paused_alert>(alert);
                if (paused_alert && paused_alert->handle == handle) paused = true;
                else enqueue_alert(owner, alert);
            }
            owner.alert_buffer.clear();
            paused = paused || static_cast<bool>(handle.status().flags & lt::torrent_flags::paused);
        }
        return paused;
    }
    handle.flush_cache();
    auto const deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    bool flushed = false;
    while (std::chrono::steady_clock::now() < deadline) {
        owner.native->wait_for_alert(std::chrono::milliseconds(100));
        owner.native->pop_alerts(&owner.alert_buffer);
        for (auto const *alert : owner.alert_buffer) {
            auto const *flushed_alert = lt::alert_cast<lt::cache_flushed_alert>(alert);
            auto const *paused_alert = lt::alert_cast<lt::torrent_paused_alert>(alert);
            if (flushed_alert && flushed_alert->handle == handle) flushed = true;
            else if (paused_alert && paused_alert->handle == handle) paused = true;
            else enqueue_alert(owner, alert);
        }
        owner.alert_buffer.clear();
        paused = paused || static_cast<bool>(handle.status().flags & lt::torrent_flags::paused);
        if (paused && flushed) return true;
    }
    return false;
}
lt::torrent_flags_t discovery_flags(lt::torrent_info const &info) { return info.priv()?lt::torrent_flags::disable_dht|lt::torrent_flags::disable_lsd|lt::torrent_flags::disable_pex:lt::torrent_flags_t{}; }
bool write_atomic(std::string const &path, std::vector<char> const &data, int *system_error = nullptr) {
    static std::atomic<uint64_t> serial{0};
    fs::path target(path);
    fs::path parent = target.parent_path();
    std::error_code ec;
    fs::create_directories(parent, ec);
    if (ec) { if (system_error) *system_error = ec.value(); return false; }
    parent = fs::weakly_canonical(parent, ec);
    if (ec) { if (system_error) *system_error = ec.value(); return false; }
    int directory = open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (directory < 0) { if (system_error) *system_error = errno; return false; }
    std::string temporary = target.filename().string() + ".tmp." + std::to_string(getpid()) + "." + std::to_string(serial.fetch_add(1));
    int fd = openat(directory, temporary.c_str(), O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0600);
    if (fd < 0) { if (system_error) *system_error = errno; close(directory); return false; }
    size_t written = 0;
    while (written < data.size()) {
        ssize_t count = write(fd, data.data() + written, data.size() - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { if (system_error) *system_error = errno; close(fd); unlinkat(directory, temporary.c_str(), 0); close(directory); return false; }
        written += static_cast<size_t>(count);
    }
    bool good = fsync(fd) == 0;
    if (!good && system_error) *system_error = errno;
    good = close(fd) == 0 && good;
    if (good) { good = renameat(directory, temporary.c_str(), directory, target.filename().c_str()) == 0; if (!good && system_error) *system_error = errno; }
    if (good) { good = fsync(directory) == 0; if (!good && system_error) *system_error = errno; }
    if (!good) unlinkat(directory, temporary.c_str(), 0);
    close(directory);
    return good;
}
void add_info_hashes(lt::info_hash_t const &hashes, tb_metadata_info &out) {
    out.has_v1 = hashes.has_v1() ? 1 : 0;
    out.has_v2 = hashes.has_v2() ? 1 : 0;
    if (hashes.has_v1()) tagged_hash(out.v1_hash, '1', hashes.v1.data(), 20);
    if (hashes.has_v2()) tagged_hash(out.v2_hash, '2', hashes.v2.data(), 32);
}
class ScopedEnvironmentOverride {
public:
    explicit ScopedEnvironmentOverride(char const *key) : key_(key) {
        if (auto const *value = std::getenv(key)) { had_value_ = true; previous_ = value; }
    }
    ~ScopedEnvironmentOverride() {
        if (!active_) return;
        if (had_value_) setenv(key_.c_str(), previous_.c_str(), 1);
        else unsetenv(key_.c_str());
    }
    bool set(std::string const &value) {
        if (setenv(key_.c_str(), value.c_str(), 1) != 0) return false;
        active_ = true;
        return true;
    }
private:
    std::string key_;
    std::string previous_;
    bool had_value_ = false;
    bool active_ = false;
};
}

extern "C" {
void tb_version(uint32_t *major,uint32_t *minor,uint32_t *patch) { if(major)*major=LIBTORRENT_VERSION_MAJOR; if(minor)*minor=LIBTORRENT_VERSION_MINOR; if(patch)*patch=LIBTORRENT_VERSION_TINY; }
 tb_error_code tb_session_create(tb_session **out, uint8_t public_network, uint32_t upload_limit, tb_error *error) {
    clear_error(error);
    if (!out) return fail(error, TB_ERROR_INVALID_ARGUMENT, "out_session is required");
    if (upload_limit == 0) return fail(error, TB_ERROR_INVALID_ARGUMENT, "upload limit must be greater than zero");
    *out = nullptr;
    static std::mutex initialization_mutex;
    try {
        std::lock_guard<std::mutex> initialization_lock(initialization_mutex);
        std::string ca_path;
        ScopedEnvironmentOverride certificate_environment("SSL_CERT_FILE");
        if (public_network) {
            CFURLRef resource_url = CFBundleCopyResourcesDirectoryURL(CFBundleGetMainBundle());
            if (!resource_url) return fail(error, TB_ERROR_IO, "trusted CA resource directory unavailable");
            CFURLRef licenses_url = CFURLCreateCopyAppendingPathComponent(kCFAllocatorDefault, resource_url, CFSTR("TorrentLicenses"), true);
            CFRelease(resource_url);
            if (!licenses_url) return fail(error, TB_ERROR_IO, "trusted CA resource unavailable");
            CFURLRef ca_url = CFURLCreateCopyAppendingPathComponent(kCFAllocatorDefault, licenses_url, CFSTR("cacert.pem"), false);
            CFRelease(licenses_url);
            if (!ca_url) return fail(error, TB_ERROR_IO, "trusted CA resource unavailable");
            CFURLRef absolute_ca_url = CFURLCopyAbsoluteURL(ca_url);
            CFRelease(ca_url);
            if (!absolute_ca_url) return fail(error, TB_ERROR_IO, "trusted CA absolute path unavailable");
            CFStringRef ca_string = CFURLCopyFileSystemPath(absolute_ca_url, kCFURLPOSIXPathStyle);
            CFRelease(absolute_ca_url);
            if (!ca_string) return fail(error, TB_ERROR_IO, "trusted CA path unavailable");
            char buffer[PATH_MAX];
            bool converted = CFStringGetCString(ca_string, buffer, sizeof(buffer), kCFStringEncodingUTF8);
            CFRelease(ca_string);
            if (!converted || !fs::is_regular_file(buffer)) return fail(error, TB_ERROR_IO, "trusted CA bundle is missing");
            ca_path = buffer;
            if (!certificate_environment.set(ca_path)) return fail(error, TB_ERROR_IO, "trusted CA configuration failed");
            // The scoped override is restored after libtorrent reads the bundle.
        }
        lt::settings_pack settings;
        settings.set_str(lt::settings_pack::listen_interfaces, public_network ? "0.0.0.0:0,[::]:0" : "127.0.0.1:0");
        settings.set_bool(lt::settings_pack::enable_dht, public_network != 0);
        settings.set_bool(lt::settings_pack::enable_lsd, public_network != 0);
        settings.set_bool(lt::settings_pack::enable_upnp, public_network != 0);
        settings.set_bool(lt::settings_pack::enable_natpmp, public_network != 0);
        settings.set_bool(lt::settings_pack::validate_https_trackers, true);
        auto const rate = static_cast<int>(std::min<uint32_t>(upload_limit, INT32_MAX));
        settings.set_int(lt::settings_pack::upload_rate_limit, rate);
        settings.set_int(lt::settings_pack::alert_mask, lt::alert_category::error | lt::alert_category::status | lt::alert_category::connect | lt::alert_category::storage);
        auto owner = std::make_unique<tb_session>();
        owner->public_network = public_network != 0;
        lt::session_params params;
        params.settings = std::move(settings);
        owner->native = std::make_unique<lt::session>(std::move(params));
        lt::settings_pack effective_limits;
        effective_limits.set_int(lt::settings_pack::upload_rate_limit, rate);
        owner->native->apply_settings(effective_limits);
        // The default LAN class is unlimited; every address must share the user cap.
        lt::ip_filter peer_classes;
        auto const global_peer_class = static_cast<std::uint32_t>(lt::session::global_peer_class_id);
        peer_classes.add_rule(lt::address_v4::any(), lt::address_v4::broadcast(), 1u << global_peer_class);
        lt::address_v6::bytes_type last_ipv6{}; last_ipv6.fill(0xff);
        peer_classes.add_rule(lt::address_v6::any(), lt::address_v6(last_ipv6), 1u << global_peer_class);
        owner->native->set_peer_class_filter(peer_classes);
        if (!public_network) {
            lt::ip_filter filter;
            filter.add_rule(lt::address_v4::any(), lt::address_v4::broadcast(), lt::ip_filter::blocked);
            filter.add_rule(lt::address_v4::loopback(), lt::address_v4::loopback(), 0);
            lt::address_v6::bytes_type bytes{}; bytes.fill(0xff);
            filter.add_rule(lt::address_v6::any(), lt::address_v6(bytes), lt::ip_filter::blocked);
            owner->native->set_ip_filter(std::move(filter));
        }
        *out = owner.release();
        return TB_OK;
    } catch (...) {
        return exception_fail(error);
    }
}
tb_error_code tb_session_set_upload_limit(tb_session *s, uint32_t rate, tb_error *error) {
    clear_error(error);
    if (!s) return fail(error, TB_ERROR_INVALID_ARGUMENT, "session required");
    try {
        std::lock_guard<std::mutex> lock(s->mutex);
        if (rate == 0) return fail(error, TB_ERROR_INVALID_ARGUMENT, "upload limit must be greater than zero");
        auto const effective = static_cast<int>(std::min<uint32_t>(rate, INT32_MAX));
        lt::settings_pack settings;
        settings.set_int(lt::settings_pack::upload_rate_limit, effective);
        s->native->apply_settings(settings);
        return TB_OK;
    } catch (...) { return exception_fail(error); }
}
 tb_error_code tb_add_torrent(tb_session *s, const char *torrent_path, const char *save_path, tb_torrent_id *out, tb_error *error) {
    clear_error(error);
    if (!s || !torrent_path || !*torrent_path || !save_path || !*save_path || !out) return fail(error, TB_ERROR_INVALID_ARGUMENT, "torrent path, save path and output are required");
    *out = 0;
    try {
        std::lock_guard<std::mutex> lock(s->mutex);
        lt::error_code ec;
        if (!validate_original_torrent(torrent_path)) return fail(error, TB_ERROR_UNSAFE_PATH, "torrent contains unsafe original path metadata");
        auto info = std::make_shared<lt::torrent_info>(torrent_path, ec);
        if (ec) return fail(error, TB_ERROR_TORRENT, "could not parse torrent metadata");
        if (!safe_destination(save_path, info->layout())) return fail(error, TB_ERROR_UNSAFE_PATH, "torrent paths or destination are unsafe");
        if (!s->public_network) info->clear_trackers();
        lt::add_torrent_params params;
        params.ti = info;
        params.save_path = save_path;
        params.flags &= ~lt::torrent_flags::auto_managed;
        params.flags |= lt::torrent_flags::paused | lt::torrent_flags::duplicate_is_error
            | lt::torrent_flags::override_trackers | lt::torrent_flags::override_web_seeds
            | lt::torrent_flags::default_dont_download | lt::torrent_flags::stop_when_ready
            | discovery_flags(*info);
        if (s->public_network) for (auto const &tracker : info->trackers()) { params.trackers.push_back(tracker.url); params.tracker_tiers.push_back(tracker.tier); }
        params.file_priorities.assign(static_cast<size_t>(info->num_files()), lt::dont_download);
        auto handle = s->native->add_torrent(std::move(params), ec);
        if (ec) return fail(error, ec.value() == ENOSPC ? TB_ERROR_DISK_FULL : TB_ERROR_TORRENT, "could not add torrent");
        handle.force_recheck();
        handle.pause();
        *out = insert_handle(*s, std::move(handle));
        return TB_OK;
    } catch (...) { return exception_fail(error); }
}
tb_error_code tb_magnet_identity(const char *uri, tb_metadata_info *out, tb_error *error) {
    clear_error(error);
    if (!uri || !out) return fail(error, TB_ERROR_INVALID_ARGUMENT, "magnet and identity output required");
    *out = {};
    try {
        lt::error_code ec;
        auto const params = lt::parse_magnet_uri(uri, ec);
        if (ec) return fail(error, TB_ERROR_TORRENT, "invalid magnet metadata");
        add_info_hashes(params.info_hashes, *out);
        return TB_OK;
    } catch (...) { return exception_fail(error); }
}
tb_error_code tb_add_magnet(tb_session *s, const char *uri, const char *save_path, tb_torrent_id *out, tb_error *error) {
    clear_error(error);
    if (!s || !uri || !*uri || !save_path || !*save_path || !out) return fail(error, TB_ERROR_INVALID_ARGUMENT, "magnet, save path and output are required");
    *out = 0;
    try {
        std::lock_guard<std::mutex> lock(s->mutex);
        lt::error_code ec;
        auto params = lt::parse_magnet_uri(uri, ec);
        if (ec) return fail(error, TB_ERROR_TORRENT, "invalid magnet metadata");
        params.save_path = save_path;
        params.flags &= ~(lt::torrent_flags::paused | lt::torrent_flags::auto_managed);
        params.flags |= lt::torrent_flags::duplicate_is_error | lt::torrent_flags::override_trackers
            | lt::torrent_flags::override_web_seeds | lt::torrent_flags::upload_mode
            | lt::torrent_flags::default_dont_download;
        params.url_seeds.clear(); params.http_seeds.clear(); params.file_priorities.clear();
        if (!s->public_network) { params.trackers.clear(); params.flags |= lt::torrent_flags::disable_dht | lt::torrent_flags::disable_lsd | lt::torrent_flags::disable_pex; }
        if (s->public_network) {
            // A dead leading tracker must not consume the entire metadata import deadline.
            // Only announce to tiers already supplied by the magnet; never add trackers.
            lt::settings_pack settings;
            settings.set_bool(lt::settings_pack::announce_to_all_tiers, true);
            s->native->apply_settings(settings);
        }
        auto handle = s->native->add_torrent(std::move(params), ec);
        if (ec) return fail(error, ec.value() == ENOSPC ? TB_ERROR_DISK_FULL : TB_ERROR_TORRENT, "could not add torrent");
        handle.resume();
        *out = insert_handle(*s, std::move(handle));
        return TB_OK;
    } catch (...) { return exception_fail(error); }
}
 tb_error_code tb_connect_loopback_peer(tb_session *s, tb_torrent_id id, uint16_t port, tb_error *error) {
    clear_error(error);
    if (!s || !port) return fail(error, TB_ERROR_INVALID_ARGUMENT, "session and port required");
    try { std::lock_guard<std::mutex> lock(s->mutex); auto *handle = find_torrent(*s, id); if (!handle) return fail(error, TB_ERROR_NOT_FOUND, "torrent not found"); handle->connect_peer(lt::tcp::endpoint(lt::address_v4::loopback(), port)); return TB_OK; }
    catch (...) { return exception_fail(error); }
}
tb_error_code tb_listen_port(tb_session*s,uint16_t*out,tb_error*error){clear_error(error);if(!s||!out)return fail(error,TB_ERROR_INVALID_ARGUMENT,"session and port required");try{std::lock_guard<std::mutex>l(s->mutex);*out=static_cast<uint16_t>(s->native->listen_port());return TB_OK;}catch(...){return exception_fail(error);}}
tb_error_code tb_get_status(tb_session *s, tb_torrent_id id, tb_torrent_status *out, tb_error *error) {
    clear_error(error);
    if (!s || !out) return fail(error, TB_ERROR_INVALID_ARGUMENT, "session and status required");
    *out = {};
    try {
        std::lock_guard<std::mutex> lock(s->mutex);
        auto *handle = find_torrent(*s, id);
        if (!handle) return fail(error, TB_ERROR_NOT_FOUND, "torrent not found");
        auto const status = handle->status();
        auto info = handle->torrent_file();
        out->total_bytes = static_cast<uint64_t>(std::max<int64_t>(0, status.total_wanted));
        out->verified_bytes = verified_bytes(*s, *handle);
        out->progress_ppm = static_cast<uint32_t>(std::clamp(status.progress_ppm, 0, 1'000'000));
        out->peers_connected = static_cast<uint32_t>(std::max(0, status.num_peers));
        out->is_finished = status.is_seeding ? 1 : 0;
        out->has_metadata = info ? 1 : 0;
        out->is_private = info && info->priv() ? 1 : 0;
        return TB_OK;
    } catch (...) { return exception_fail(error); }
}
tb_error_code tb_get_metadata(tb_session *s, tb_torrent_id id, tb_metadata_info *out, tb_file_info *files, uint32_t capacity, tb_error *error) {
    clear_error(error);
    if (!s || !out) return fail(error, TB_ERROR_INVALID_ARGUMENT, "session and metadata output required");
    *out = {};
    try {
        std::lock_guard<std::mutex> lock(s->mutex);
        auto *handle = find_torrent(*s, id);
        if (!handle) return fail(error, TB_ERROR_NOT_FOUND, "torrent not found");
        if (s->unsafe_metadata.count(id)) return fail(error, TB_ERROR_UNSAFE_PATH, "torrent metadata contains unsafe paths");
        auto info = handle->torrent_file();
        if (!info) return fail(error, TB_ERROR_METADATA_PENDING, "metadata pending");
        auto const &layout = info->layout();
        if (!validate_info_metadata(*info) || !safe_destination(handle->status(lt::torrent_handle::query_save_path).save_path, layout)) return fail(error, TB_ERROR_UNSAFE_PATH, "torrent paths or destination are unsafe");
        out->file_count = static_cast<uint32_t>(layout.num_files());
        add_info_hashes(info->info_hashes(), *out);
        out->is_private = info->priv() ? 1 : 0;
        if (!files) return capacity == 0 ? TB_OK : fail(error, TB_ERROR_INVALID_ARGUMENT, "file storage required");
        if (capacity < out->file_count) return fail(error, TB_ERROR_INVALID_ARGUMENT, "file buffer too small");
        for (int i = 0; i < layout.num_files(); ++i) {
            auto const index = lt::file_index_t{i};
            auto path = layout.file_path(index);
            if (path.size() >= sizeof(files[i].path)) return fail(error, TB_ERROR_UNSAFE_PATH, "torrent path exceeds bridge capacity");
            files[i] = {};
            files[i].size = static_cast<uint64_t>(std::max<int64_t>(0, layout.file_size(index)));
            files[i].pad_file = layout.pad_file_at(index) ? 1 : 0;
            std::memcpy(files[i].path, path.c_str(), path.size() + 1);
        }
        return TB_OK;
    } catch (...) { return exception_fail(error); }
}
tb_error_code tb_set_file_priorities(tb_session *s, tb_torrent_id id, uint8_t const *priorities, uint32_t count, tb_error *error) {
    clear_error(error);
    if (!s || (!priorities && count)) return fail(error, TB_ERROR_INVALID_ARGUMENT, "session and priorities required");
    try {
        std::lock_guard<std::mutex> lock(s->mutex);
        auto *handle = find_torrent(*s, id);
        if (!handle) return fail(error, TB_ERROR_NOT_FOUND, "torrent not found");
        if (s->unsafe_metadata.count(id)) return fail(error, TB_ERROR_UNSAFE_PATH, "torrent metadata contains unsafe paths");
        auto info = handle->torrent_file();
        if (!info) return fail(error, TB_ERROR_METADATA_PENDING, "metadata pending");
        auto const &layout = info->layout();
        if (!validate_info_metadata(*info) || !safe_destination(handle->status(lt::torrent_handle::query_save_path).save_path, layout)) return fail(error, TB_ERROR_UNSAFE_PATH, "torrent paths or destination are unsafe");
        if (count != static_cast<uint32_t>(info->num_files())) return fail(error, TB_ERROR_INVALID_ARGUMENT, "priority count does not match files");
        std::vector<lt::download_priority_t> native_priorities;
        native_priorities.reserve(count);
        bool selected = false;
        for (uint32_t i = 0; i < count; ++i) {
            if (priorities[i] > 7 || (layout.pad_file_at(lt::file_index_t{static_cast<int>(i)}) && priorities[i] != 0)) return fail(error, TB_ERROR_INVALID_ARGUMENT, "invalid file priority");
            native_priorities.emplace_back(priorities[i]);
            selected = selected || priorities[i] != 0;
        }
        handle->prioritize_files(native_priorities);
        if (selected) handle->unset_flags(lt::torrent_flags::stop_when_ready | lt::torrent_flags::upload_mode);
        return TB_OK;
    } catch (...) { return exception_fail(error); }
}
tb_error_code tb_get_file_progress(tb_session *s, tb_torrent_id id, uint64_t *out, uint32_t capacity, uint32_t *count, tb_error *error) {
    clear_error(error);
    if (!s || !count) return fail(error, TB_ERROR_INVALID_ARGUMENT, "session and count required");
    *count = 0;
    try {
        std::lock_guard<std::mutex> lock(s->mutex);
        auto *handle = find_torrent(*s, id);
        if (!handle) return fail(error, TB_ERROR_NOT_FOUND, "torrent not found");
        auto info = handle->torrent_file();
        if (!info) return fail(error, TB_ERROR_METADATA_PENDING, "metadata pending");
        *count = static_cast<uint32_t>(info->num_files());
        if (capacity < *count || (!out && *count)) return fail(error, TB_ERROR_INVALID_ARGUMENT, "progress buffer too small");
        if (!progress_is_validated(*handle)) {
            if (*count) std::fill(out, out + *count, uint64_t(0));
            return TB_OK;
        }
        handle->file_progress(s->progress_buffer, lt::torrent_handle::piece_granularity);
        auto const &files = info->layout();
        for (uint32_t i = 0; i < *count; ++i) {
            auto const index = lt::file_index_t{static_cast<int>(i)};
            auto const bytes = std::max<int64_t>(0, s->progress_buffer[i]);
            out[i] = static_cast<uint64_t>(std::min<int64_t>(bytes, files.file_size(index)));
        }
        return TB_OK;
    } catch (...) { return exception_fail(error); }
}
tb_error_code tb_pause_torrent(tb_session *s, tb_torrent_id id, tb_error *error) {
    clear_error(error);
    if (!s) return fail(error, TB_ERROR_INVALID_ARGUMENT, "session required");
    try {
        std::lock_guard<std::mutex> lock(s->mutex);
        auto *handle = find_torrent(*s, id);
        if (!handle) return fail(error, TB_ERROR_NOT_FOUND, "torrent not found");
        if (!stop_and_flush(*s, *handle)) return fail(error, TB_ERROR_TIMEOUT, "torrent writer shutdown timed out");
        return TB_OK;
    } catch (...) { return exception_fail(error); }
}
tb_error_code tb_resume_torrent(tb_session *s, tb_torrent_id id, tb_error *error) {
    clear_error(error);
    if (!s) return fail(error, TB_ERROR_INVALID_ARGUMENT, "session required");
    try {
        std::lock_guard<std::mutex> lock(s->mutex);
        auto *handle = find_torrent(*s, id);
        if (!handle) return fail(error, TB_ERROR_NOT_FOUND, "torrent not found");
        if (s->unsafe_metadata.count(id)) return fail(error, TB_ERROR_UNSAFE_PATH, "torrent metadata contains unsafe paths");
        auto info = handle->torrent_file();
        if (info && !validate_info_metadata(*info)) return fail(error, TB_ERROR_UNSAFE_PATH, "torrent metadata contains unsafe paths");
        handle->resume();
        return TB_OK;
    } catch (...) { return exception_fail(error); }
}
tb_error_code tb_remove_torrent(tb_session *s, tb_torrent_id id, uint8_t delete_files, tb_error *error) {
    clear_error(error);
    if (!s) return fail(error, TB_ERROR_INVALID_ARGUMENT, "session required");
    try {
        std::lock_guard<std::mutex> lock(s->mutex);
        auto it = s->torrents.find(id);
        if (it == s->torrents.end()) return fail(error, TB_ERROR_NOT_FOUND, "torrent not found");
        if (!stop_and_flush(*s, it->second)) return fail(error, TB_ERROR_TIMEOUT, "torrent writer shutdown timed out");
        auto const flags = delete_files ? lt::session::delete_files : lt::remove_flags_t{};
        s->native->remove_torrent(it->second, flags);
        s->torrents.erase(it);
        for (auto event = s->events.begin(); event != s->events.end();) {
            if (event->torrent_id == id) event = s->events.erase(event);
            else ++event;
        }
        s->unsafe_metadata.erase(id);
        return TB_OK;
    } catch (...) { return exception_fail(error); }
}
tb_error_code tb_save_resume(tb_session *s, tb_torrent_id id, const char *resume_path, const char *metadata_path, tb_error *error) {
    clear_error(error);
    if (!s || !resume_path || !metadata_path) return fail(error, TB_ERROR_INVALID_ARGUMENT, "session and resume paths required");
    try {
        std::lock_guard<std::mutex> lock(s->mutex);
        auto *handle = find_torrent(*s, id);
        if (!handle) return fail(error, TB_ERROR_NOT_FOUND, "torrent not found");
        if (!handle->torrent_file()) return fail(error, TB_ERROR_METADATA_PENDING, "torrent metadata pending");
        handle->save_resume_data(lt::torrent_handle::flush_disk_cache | lt::torrent_handle::save_info_dict);

        auto const deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        std::vector<char> resume_bytes;
        std::vector<char> metadata_bytes;
        bool saved = false;
        while (std::chrono::steady_clock::now() < deadline && !saved) {
            s->native->wait_for_alert(std::chrono::milliseconds(100));
            s->native->pop_alerts(&s->alert_buffer);
            for (auto *alert : s->alert_buffer) {
                if (auto *done = lt::alert_cast<lt::save_resume_data_alert>(alert); done && done->handle == *handle) {
                    resume_bytes = lt::write_resume_data_buf(done->params);
                    // Sparse v2 trees belong in resume.dat, not exported piece layers.
                    // Keep the companion as identity/layout metadata even before hashes arrive.
                    done->params.merkle_trees.clear();
                    metadata_bytes = lt::write_torrent_file_buf(done->params, lt::write_flags::allow_missing_piece_layer);
                    saved = true;
                } else if (auto const *failed = lt::alert_cast<lt::save_resume_data_failed_alert>(alert); failed && failed->handle == *handle) {
                    s->alert_buffer.clear();
                    return fail(error, TB_ERROR_IO, "libtorrent could not save resume data");
                } else {
                    enqueue_alert(*s, alert);
                }
            }
            s->alert_buffer.clear();
        }
        if (!saved || resume_bytes.empty() || metadata_bytes.empty()) return fail(error, TB_ERROR_TIMEOUT, "resume save timed out");
        int system_error = 0;
        if (!write_atomic(metadata_path, metadata_bytes, &system_error)
            || !write_atomic(resume_path, resume_bytes, &system_error)) {
            return fail(error, system_error == ENOSPC ? TB_ERROR_DISK_FULL : TB_ERROR_IO, "atomic resume save failed");
        }
        return TB_OK;
    } catch (...) { return exception_fail(error); }
}
tb_error_code tb_load_resume(tb_session *s, const char *resume_path, const char *metadata_path, const char *save_path, tb_torrent_id *out, tb_error *error) {
    clear_error(error);
    if (!s || !resume_path || !metadata_path || !save_path || !out) return fail(error, TB_ERROR_INVALID_ARGUMENT, "resume paths and output required");
    *out = 0;
    try {
        std::lock_guard<std::mutex> lock(s->mutex);
        auto const metadata_bytes = read_attachment(metadata_path);
        if (metadata_bytes.empty()
            || !validate_torrent_bytes(lt::span<char const>(metadata_bytes.data(), metadata_bytes.size()))) {
            return fail(error, TB_ERROR_CORRUPT_RESUME, "saved torrent metadata is missing or corrupt");
        }
        lt::error_code ec;
        auto companion_info = std::make_shared<lt::torrent_info>(
            lt::span<char const>(metadata_bytes.data(), metadata_bytes.size()), ec, lt::from_span);
        if (ec || !safe_destination(save_path, companion_info->layout())) {
            return fail(error, TB_ERROR_UNSAFE_PATH, "saved torrent paths or destination are unsafe");
        }

        auto const resume_bytes = read_attachment(resume_path);
        lt::add_torrent_params params;
        bool valid_resume = !resume_bytes.empty();
        if (valid_resume) {
            params = lt::read_resume_data(lt::span<char const>(resume_bytes.data(), resume_bytes.size()), ec);
            valid_resume = !ec;
        }
        if (valid_resume) {
            auto const resume_hashes = params.ti ? params.ti->info_hashes() : params.info_hashes;
            valid_resume = (resume_hashes.has_v1() || resume_hashes.has_v2())
                && resume_hashes == companion_info->info_hashes();
        }
        if (valid_resume && !params.file_priorities.empty()) {
            valid_resume = params.file_priorities.size() == static_cast<size_t>(companion_info->num_files());
            if (valid_resume) for (int i = 0; i < companion_info->num_files(); ++i) {
                auto const index = lt::file_index_t{i};
                if (static_cast<std::uint8_t>(params.file_priorities[static_cast<size_t>(i)]) > 7
                    || (companion_info->layout().pad_file_at(index) && params.file_priorities[static_cast<size_t>(i)] != lt::dont_download)) {
                    valid_resume = false;
                    break;
                }
            }
        }

        if (!valid_resume) {
            params = {};
            params.ti = companion_info;
            params.file_priorities.assign(static_cast<size_t>(companion_info->num_files()), lt::dont_download);
        } else if (!params.ti) {
            params.ti = companion_info;
        }
        params.save_path = save_path;
        params.ti = companion_info;
        params.url_seeds.clear();
        params.http_seeds.clear();
        params.renamed_files.clear();
        // Initial fast-resume checking ignores force_recheck(). Omit trusted
        // completion bits so libtorrent hashes real files before reporting bytes.
        params.have_pieces.clear();
        params.verified_pieces.clear();
        params.unfinished_pieces.clear();
        params.verified_leaf_hashes.clear();
        params.flags = lt::torrent_flags::duplicate_is_error | lt::torrent_flags::override_trackers
            | lt::torrent_flags::override_web_seeds | lt::torrent_flags::default_dont_download
            | lt::torrent_flags::paused | discovery_flags(*companion_info);
        params.trackers.clear();
        params.tracker_tiers.clear();
        if (s->public_network) {
            for (auto const &tracker : companion_info->trackers()) {
                params.trackers.push_back(tracker.url);
                params.tracker_tiers.push_back(tracker.tier);
            }
        }
        auto handle = s->native->add_torrent(std::move(params), ec);
        if (ec) return fail(error, ec.value() == ENOSPC ? TB_ERROR_DISK_FULL : TB_ERROR_TORRENT, "could not restore torrent session");
        *out = insert_handle(*s, std::move(handle));
        return TB_OK;
    } catch (...) { return exception_fail(error); }
}
tb_error_code tb_poll_events(tb_session*s,tb_event*events,uint32_t cap,uint32_t*out_count,tb_error*error){clear_error(error);if(!s||!out_count||(cap&&!events))return fail(error,TB_ERROR_INVALID_ARGUMENT,"session, count and event storage required");*out_count=0;if(!cap)return TB_OK;try{std::lock_guard<std::mutex>l(s->mutex);if(s->events.empty())harvest_alerts(*s);while(*out_count<cap&&!s->events.empty()){events[*out_count]=s->events.front();s->events.pop_front();++*out_count;}return TB_OK;}catch(...){return exception_fail(error);}}
tb_error_code tb_reader_open(tb_session *s, tb_torrent_id torrent_id, uint32_t file_index, uint64_t *out_id, tb_error *error) {
    clear_error(error);
    if (!s || !out_id) return fail(error, TB_ERROR_INVALID_ARGUMENT, "session and reader output required");
    *out_id = 0;
    try {
        std::lock_guard<std::mutex> lock(s->mutex);
        if (s->closing) return fail(error, TB_ERROR_CANCELLED, "session is closing");
        auto *handle = find_torrent(*s, torrent_id);
        if (!handle) return fail(error, TB_ERROR_NOT_FOUND, "torrent not found");
        if (s->unsafe_metadata.count(torrent_id)) return fail(error, TB_ERROR_UNSAFE_PATH, "torrent metadata contains unsafe paths");
        auto info = handle->torrent_file();
        if (!info) return fail(error, TB_ERROR_METADATA_PENDING, "torrent metadata pending");
        auto const &files = info->layout();
        if (file_index >= static_cast<uint32_t>(files.num_files())) return fail(error, TB_ERROR_INVALID_ARGUMENT, "file index out of range");
        auto const index = lt::file_index_t{static_cast<int>(file_index)};
        if (files.pad_file_at(index) || files.file_size(index) < 0) return fail(error, TB_ERROR_INVALID_ARGUMENT, "file is not readable");
        if (info->piece_length() <= 0 || info->piece_length() > 16 * 1024 * 1024) return fail(error, TB_ERROR_INVALID_ARGUMENT, "piece length exceeds bounded reader limit");
        if (s->readers.size() >= 32) return fail(error, TB_ERROR_INTERNAL, "reader limit reached");
        uint64_t id = s->next_reader_id++;
        if (!id) id = s->next_reader_id++;
        s->readers.emplace(id, tb_reader{torrent_id, static_cast<int>(file_index), {}});
        *out_id = id;
        return TB_OK;
    } catch (...) { return exception_fail(error); }
}
tb_error_code tb_reader_read(tb_session *s, uint64_t reader_id, uint64_t request_id, uint64_t offset, uint32_t requested, uint32_t timeout_ms, uint8_t *buffer, uint32_t capacity, uint32_t *out_length, tb_error *error) {
    clear_error(error);
    if (!s || !out_length || (capacity && !buffer)) return fail(error, TB_ERROR_INVALID_ARGUMENT, "session, output length and buffer required");
    *out_length = 0;
    if (request_id == 0 || requested == 0 || capacity == 0) return fail(error, TB_ERROR_INVALID_ARGUMENT, "request id, read length and capacity must be nonzero");
    try {
        std::unique_lock<std::mutex> lock(s->mutex);
        auto reader_it = s->readers.find(reader_id);
        if (reader_it == s->readers.end()) return fail(error, TB_ERROR_NOT_FOUND, "reader not found");
        if (s->closing) return fail(error, TB_ERROR_CANCELLED, "session is closing");
        if (reader_it->second.active) return fail(error, TB_ERROR_INVALID_ARGUMENT, "reader already has an active read");
        if (reader_it->second.cancelled_requests.erase(request_id)) { reader_it->second.last_completed_request = std::max(reader_it->second.last_completed_request, request_id); return fail(error, TB_ERROR_CANCELLED, "piece read cancelled"); }
        if (request_id <= reader_it->second.last_completed_request) return fail(error, TB_ERROR_INVALID_ARGUMENT, "stale read request id");
        auto *handle = find_torrent(*s, reader_it->second.torrent);
        if (!handle) return fail(error, TB_ERROR_NOT_FOUND, "torrent not found");
        auto info = handle->torrent_file();
        if (!info) return fail(error, TB_ERROR_METADATA_PENDING, "torrent metadata pending");
        auto const &files = info->layout();
        auto const file = lt::file_index_t{reader_it->second.file};
        auto const signed_size = files.file_size(file);
        if (signed_size < 0) return fail(error, TB_ERROR_TORRENT, "invalid file size");
        uint64_t const file_size = static_cast<uint64_t>(signed_size);
        if (offset > file_size) return fail(error, TB_ERROR_INVALID_ARGUMENT, "offset exceeds file size");
        if (offset == file_size) { reader_it->second.last_completed_request = std::max(reader_it->second.last_completed_request, request_id); return TB_OK; }
        int const piece_length = info->piece_length();
        if (piece_length <= 0) return fail(error, TB_ERROR_TORRENT, "invalid torrent piece length");
        uint64_t const torrent_offset = static_cast<uint64_t>(files.file_offset(file)) + offset;
        uint64_t const piece_number = torrent_offset / static_cast<uint64_t>(piece_length);
        uint32_t const piece_offset = static_cast<uint32_t>(torrent_offset % static_cast<uint64_t>(piece_length));
        uint64_t const available = std::min<uint64_t>({static_cast<uint64_t>(requested), uint64_t(256 * 1024), file_size - offset, static_cast<uint64_t>(piece_length) - piece_offset});
        if (available == 0 || capacity < available) return fail(error, TB_ERROR_INVALID_ARGUMENT, "output buffer too small");
        harvest_alerts(*s);
        auto request = std::make_shared<tb_reader_request>();
        request->piece_offset = piece_offset;
        request->length = static_cast<uint32_t>(available);
        request->buffer = buffer;
        auto const key = std::make_pair(reader_it->second.torrent, static_cast<int>(piece_number));
        auto &waiters = s->piece_waiters[key];
        bool const first = waiters.empty();
        waiters.push_back(request);
        reader_it->second.active = request;
        reader_it->second.active_request = request_id;
        ++s->active_reads;
        tb_reader_read_guard read_guard{*s, lock, reader_id, request_id, key, request};
        if (first) handle->set_piece_deadline(lt::piece_index_t{static_cast<int>(piece_number)}, 0, lt::torrent_handle::alert_when_available);
        auto const deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
        while (!request->complete && !s->closing) {
            if (std::chrono::steady_clock::now() >= deadline) break;
            lock.unlock();
            s->native->wait_for_alert(std::chrono::milliseconds(50));
            lock.lock();
            if (s->native) harvest_alerts(*s);
        }
        bool const timed_out = !request->complete && !s->closing;
        if (!request->complete) {
            request->cancelled = true;
            request->complete = true;
            request->code = s->closing ? TB_ERROR_CANCELLED : TB_ERROR_TIMEOUT;
            retire_piece_waiter(*s, key, request);
        }
        read_guard.finish();
        if (timed_out) return fail(error, TB_ERROR_TIMEOUT, "piece read timed out");
        if (request->code != TB_OK) return fail(error, request->code, request->code == TB_ERROR_CANCELLED ? "piece read cancelled" : "piece read failed");
        *out_length = request->length;
        return TB_OK;
    } catch (...) { return exception_fail(error); }
}
tb_error_code tb_reader_cancel_read(tb_session *s, uint64_t reader_id, uint64_t request_id, tb_error *error) {
    clear_error(error);
    if (!s) return fail(error, TB_ERROR_INVALID_ARGUMENT, "session required");
    std::lock_guard<std::mutex> lock(s->mutex);
    auto it = s->readers.find(reader_id);
    if (it == s->readers.end()) return fail(error, TB_ERROR_NOT_FOUND, "reader not found");
    auto request = it->second.active;
    if (it->second.active_request == request_id && request && !request->complete) {
        request->cancelled = true; request->complete = true; request->code = TB_ERROR_CANCELLED;
        for (auto waiter = s->piece_waiters.begin(); waiter != s->piece_waiters.end(); ++waiter) if (std::find(waiter->second.begin(), waiter->second.end(), request) != waiter->second.end()) { retire_piece_waiter(*s, waiter->first, request); break; }
        s->readers_changed.notify_all();
    } else if (request_id > it->second.last_completed_request) {
        if (it->second.cancelled_requests.size() >= 32) return fail(error, TB_ERROR_INTERNAL, "too many pending reader cancellations");
        it->second.cancelled_requests.insert(request_id);
    }
    return TB_OK;
}
tb_error_code tb_reader_close(tb_session *s, uint64_t reader_id, tb_error *error) {
    clear_error(error);
    if (!s) return fail(error, TB_ERROR_INVALID_ARGUMENT, "session required");
    std::lock_guard<std::mutex> lock(s->mutex);
    auto it = s->readers.find(reader_id);
    if (it == s->readers.end()) return fail(error, TB_ERROR_NOT_FOUND, "reader not found");
    auto request = it->second.active;
    if (request && !request->complete) {
        request->complete = true; request->cancelled = true; request->code = TB_ERROR_CANCELLED;
        for (auto waiter = s->piece_waiters.begin(); waiter != s->piece_waiters.end(); ++waiter) if (std::find(waiter->second.begin(), waiter->second.end(), request) != waiter->second.end()) { retire_piece_waiter(*s, waiter->first, request); break; }
        s->readers_changed.notify_all();
    }
    s->readers.erase(it);
    return TB_OK;
}
void tb_session_cancel_readers(tb_session *s) {
    if (!s) return;
    std::lock_guard<std::mutex> lock(s->mutex);
    s->closing = true;
    for (auto &reader : s->readers) {
        auto request = reader.second.active;
        if (request && !request->complete) { request->complete = true; request->cancelled = true; request->code = TB_ERROR_CANCELLED; }
    }
    for (auto const &waiter : s->piece_waiters) if (auto *handle = find_torrent(*s, waiter.first.first)) handle->reset_piece_deadline(lt::piece_index_t{waiter.first.second});
    s->piece_waiters.clear();
    s->readers_changed.notify_all();
}
void tb_session_close(tb_session *s) {
    if (!s) return;
    try {
        std::unique_lock<std::mutex> lock(s->mutex);
        s->closing = true;
        for (auto &reader : s->readers) {
            auto request = reader.second.active;
            if (request && !request->complete) { request->complete = true; request->cancelled = true; request->code = TB_ERROR_CANCELLED; }
        }
        for (auto &waiter : s->piece_waiters) if (auto *handle = find_torrent(*s, waiter.first.first)) handle->reset_piece_deadline(lt::piece_index_t{waiter.first.second});
        s->piece_waiters.clear();
        s->readers_changed.notify_all();
        s->readers_changed.wait(lock, [s] { return s->active_reads == 0; });
        if (s->native) {
            for (auto const &item : s->torrents) stop_and_flush(*s, item.second);
            auto proxy = s->native->abort();
            s->native.reset();
        }
        s->torrents.clear();
        s->unsafe_metadata.clear();
    } catch (...) {}
    delete s;
}
}
