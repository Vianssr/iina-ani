#include <libtorrent/create_torrent.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/file_storage.hpp>

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
std::int64_t fixture_file_size(std::filesystem::path const &path) {
    std::error_code error;
    auto const size = std::filesystem::file_size(path, error);
    if (error || size == 0 || size > static_cast<std::uintmax_t>(INT64_MAX)) {
        throw std::runtime_error("fixture files must exist and be non-empty");
    }
    return static_cast<std::int64_t>(size);
}
}

int main(int argc, char **argv) {
    if (argc < 3 || argc > 6) {
        std::cerr << "usage: torrent-fixture <seed-directory> <output.torrent> [v1|v2|hybrid] [multi] [private]\n";
        return 2;
    }

    try {
        std::filesystem::path const seed_directory(argv[1]);
        std::string const mode = argc >= 4 ? argv[3] : "v1";
        bool const multi = argc >= 5 && std::string(argv[4]) == "multi";
        std::string const payload_name = multi ? "payload.mkv" : "payload.bin";
        if (argc >= 5 && !multi) throw std::runtime_error("the fourth argument must be multi");
        bool const private_torrent = argc == 6 && std::string(argv[5]) == "private";
        if (argc == 6 && !private_torrent) throw std::runtime_error("the fifth argument must be private");
        auto flags = libtorrent::create_torrent::v1_only;
        if (mode == "v2") flags = libtorrent::create_torrent::v2_only;
        else if (mode == "hybrid") flags = {};
        else if (mode != "v1") throw std::runtime_error("protocol must be v1, v2 or hybrid");

        auto const root_name = seed_directory.filename();
        libtorrent::file_storage files;
        if (multi) files.add_file(root_name / "decoy.bin", fixture_file_size(seed_directory / "decoy.bin"));
        files.add_file(multi ? root_name / payload_name : std::filesystem::path(payload_name),
                       fixture_file_size(seed_directory / payload_name));
        libtorrent::create_torrent torrent(files, 0, flags);
        torrent.set_priv(private_torrent);
        libtorrent::error_code error;
        auto const content_root = multi ? seed_directory.parent_path() : seed_directory;
        libtorrent::set_piece_hashes(torrent, content_root.string(), error);
        if (error) {
            std::cerr << "failed to hash fixture data\n";
            return 1;
        }

        std::vector<char> bytes = torrent.generate_buf();
        std::ofstream output(argv[2], std::ios::binary | std::ios::trunc);
        if (!output || !output.write(bytes.data(), static_cast<std::streamsize>(bytes.size()))) {
            std::cerr << "failed to write torrent file\n";
            return 1;
        }
        return 0;
    } catch (std::exception const &error) {
        std::cerr << "failed to create torrent: " << error.what() << '\n';
        return 1;
    } catch (...) {
        std::cerr << "failed to create torrent: unknown native exception\n";
        return 1;
    }
}
