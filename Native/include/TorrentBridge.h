#ifndef IINA_TORRENT_BRIDGE_H
#define IINA_TORRENT_BRIDGE_H

#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct tb_session tb_session;
typedef uint32_t tb_torrent_id;
typedef enum tb_error_code { TB_OK=0, TB_ERROR_INVALID_ARGUMENT=1, TB_ERROR_IO=2, TB_ERROR_TORRENT=3, TB_ERROR_NOT_FOUND=4, TB_ERROR_INTERNAL=5, TB_ERROR_DISK_FULL=6, TB_ERROR_UNSAFE_PATH=7, TB_ERROR_METADATA_PENDING=8, TB_ERROR_CORRUPT_RESUME=9, TB_ERROR_TIMEOUT=10, TB_ERROR_CANCELLED=11 } tb_error_code;
typedef struct tb_error { tb_error_code code; char message[256]; } tb_error;
typedef enum tb_event_type { TB_EVENT_TORRENT_FINISHED=1, TB_EVENT_TORRENT_ERROR=2, TB_EVENT_STATE_CHANGED=3, TB_EVENT_PEER_CONNECTED=4, TB_EVENT_METADATA_RECEIVED=5, TB_EVENT_RESUME_SAVED=6 } tb_event_type;
typedef struct tb_event { tb_event_type type; tb_torrent_id torrent_id; int32_t error_code; uint64_t verified_bytes; uint64_t total_bytes; char message[256]; } tb_event;
typedef struct tb_torrent_status { uint64_t total_bytes; uint64_t verified_bytes; uint32_t progress_ppm; uint32_t peers_connected; uint8_t is_finished; uint8_t has_metadata; uint8_t is_private; uint8_t reserved[5]; } tb_torrent_status;
typedef struct tb_file_info { uint64_t size; uint8_t pad_file; uint8_t reserved[7]; char path[1024]; } tb_file_info;
typedef struct tb_metadata_info { uint32_t file_count; uint8_t has_v1; uint8_t has_v2; uint8_t is_private; uint8_t reserved; char v1_hash[45]; char v2_hash[69]; } tb_metadata_info;

void tb_version(uint32_t *major,uint32_t *minor,uint32_t *patch);
tb_error_code tb_session_create(tb_session **out_session,uint8_t public_network,uint32_t upload_limit_bytes_per_second,tb_error *error);
tb_error_code tb_session_set_upload_limit(tb_session *session,uint32_t bytes_per_second,tb_error *error);
tb_error_code tb_add_torrent(tb_session *session,const char *torrent_path,const char *save_path,tb_torrent_id *out_id,tb_error *error);
tb_error_code tb_magnet_identity(const char *magnet_uri,tb_metadata_info *out_info,tb_error *error);
tb_error_code tb_add_magnet(tb_session *session,const char *magnet_uri,const char *save_path,tb_torrent_id *out_id,tb_error *error);
tb_error_code tb_connect_loopback_peer(tb_session *session,tb_torrent_id torrent_id,uint16_t port,tb_error *error);
tb_error_code tb_listen_port(tb_session *session,uint16_t *out_port,tb_error *error);
tb_error_code tb_get_status(tb_session *session,tb_torrent_id torrent_id,tb_torrent_status *out_status,tb_error *error);
tb_error_code tb_get_metadata(tb_session *session,tb_torrent_id torrent_id,tb_metadata_info *out_info,tb_file_info *files,uint32_t capacity,tb_error *error);
tb_error_code tb_set_file_priorities(tb_session *session,tb_torrent_id torrent_id,const uint8_t *priorities,uint32_t count,tb_error *error);
tb_error_code tb_get_file_progress(tb_session *session,tb_torrent_id torrent_id,uint64_t *progress,uint32_t capacity,uint32_t *out_count,tb_error *error);
tb_error_code tb_pause_torrent(tb_session *session,tb_torrent_id torrent_id,tb_error *error);
tb_error_code tb_resume_torrent(tb_session *session,tb_torrent_id torrent_id,tb_error *error);
tb_error_code tb_remove_torrent(tb_session *session,tb_torrent_id torrent_id,uint8_t delete_files,tb_error *error);
tb_error_code tb_save_resume(tb_session *session,tb_torrent_id torrent_id,const char *resume_path,const char *metadata_path,tb_error *error);
tb_error_code tb_load_resume(tb_session *session,const char *resume_path,const char *metadata_path,const char *save_path,tb_torrent_id *out_id,tb_error *error);
tb_error_code tb_poll_events(tb_session *session,tb_event *events,uint32_t capacity,uint32_t *out_count,tb_error *error);
tb_error_code tb_reader_open(tb_session *session,tb_torrent_id torrent_id,uint32_t file_index,uint64_t *out_reader_id,tb_error *error);
tb_error_code tb_reader_read(tb_session *session,uint64_t reader_id,uint64_t request_id,uint64_t offset,uint32_t requested_length,uint32_t timeout_milliseconds,uint8_t *buffer,uint32_t capacity,uint32_t *out_length,tb_error *error);
tb_error_code tb_reader_cancel_read(tb_session *session,uint64_t reader_id,uint64_t request_id,tb_error *error);
tb_error_code tb_reader_close(tb_session *session,uint64_t reader_id,tb_error *error);
void tb_session_cancel_readers(tb_session *session);
void tb_session_close(tb_session *session);
#ifdef __cplusplus
}
#endif
#endif
