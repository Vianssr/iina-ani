cmake_minimum_required(VERSION 3.20)
project(iina_torrent LANGUAGES C CXX)

if(NOT DEFINED LIBTORRENT_SOURCE_DIR OR NOT IS_DIRECTORY "${LIBTORRENT_SOURCE_DIR}")
    message(FATAL_ERROR "LIBTORRENT_SOURCE_DIR must name the verified libtorrent source tree")
endif()
if(NOT DEFINED BOOST_ROOT OR NOT IS_DIRECTORY "${BOOST_ROOT}")
    message(FATAL_ERROR "BOOST_ROOT must name the locked Boost source tree")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.5" CACHE STRING "Minimum macOS version" FORCE)
set(CMAKE_FIND_FRAMEWORK LAST)
set(Boost_NO_BOOST_CMAKE ON)
set(Boost_NO_SYSTEM_PATHS ON)
set(Boost_ROOT "${BOOST_ROOT}" CACHE PATH "Pinned Boost headers" FORCE)
set(BOOST_ROOT "${BOOST_ROOT}" CACHE PATH "Pinned Boost headers" FORCE)

set(OPENSSL_USE_STATIC_LIBS TRUE)
find_package(OpenSSL REQUIRED)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build static libraries" FORCE)
set(build_tests OFF CACHE BOOL "" FORCE)
set(build_examples OFF CACHE BOOL "" FORCE)
set(build_tools OFF CACHE BOOL "" FORCE)
set(python-bindings OFF CACHE BOOL "" FORCE)
set(webtorrent OFF CACHE BOOL "Disable WebTorrent dependency tree" FORCE)
set(dht ON CACHE BOOL "Enable DHT support" FORCE)
set(encryption ON CACHE BOOL "Enable built-in peer encryption" FORCE)
set(gnutls OFF CACHE BOOL "" FORCE)

add_subdirectory("${LIBTORRENT_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/libtorrent")

add_library(iina_torrent STATIC src/TorrentBridge.cpp)
target_include_directories(iina_torrent PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(iina_torrent PUBLIC torrent-rasterbar)
set_target_properties(iina_torrent PROPERTIES
    OUTPUT_NAME iina_torrent
    ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_INSTALL_PREFIX}/lib"
)
install(TARGETS iina_torrent ARCHIVE DESTINATION lib)
install(FILES include/TorrentBridge.h DESTINATION include)

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/src/TorrentFixture.cpp")
    add_executable(torrent_fixture src/TorrentFixture.cpp)
    target_link_libraries(torrent_fixture PRIVATE torrent-rasterbar OpenSSL::SSL)
    set_target_properties(torrent_fixture PROPERTIES
        OUTPUT_NAME torrent-fixture
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    )
    install(TARGETS torrent_fixture RUNTIME DESTINATION bin)
endif()
install(FILES
    "${CMAKE_CURRENT_SOURCE_DIR}/licenses/libtorrent-LICENSE.txt"
    "${CMAKE_CURRENT_SOURCE_DIR}/licenses/boost-LICENSE_1_0.txt"
    "${CMAKE_CURRENT_SOURCE_DIR}/licenses/try_signal-LICENSE.txt"
    "${CMAKE_CURRENT_SOURCE_DIR}/licenses/openssl-LICENSE.txt"
    "${CMAKE_CURRENT_SOURCE_DIR}/licenses/MPL-2.0.txt"
    DESTINATION share/licenses/iina-torrent
)
install(FILES
    "${CMAKE_CURRENT_SOURCE_DIR}/licenses/cacert.pem"
    DESTINATION share/iina-torrent
)
