// A minimal C++ wrapper of the C interface, as an audio plugin would use it:
// the licence is checked on a background thread, never on the audio thread,
// and the processor reads one atomic flag.
//
//   plugin_licence <state-file> [key]
//
// Env: LW_URL, LW_PUBLIC_KEY_1, LW_PUBLIC_KEY_2 (base64; kids "k1", "k2").
#include "license_worker.h"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <thread>

namespace lw {

// Owns a string the library returned.
struct String {
  char *p = nullptr;
  ~String() { lw_string_free(p); }
  std::string str() const { return p ? p : ""; }
};

// Owns a status.
struct Status : LwStatus {
  Status() : LwStatus{} {}
  ~Status() { lw_status_clear(this); }
  Status(const Status &) = delete;
  Status &operator=(const Status &) = delete;
};

class Licence {
 public:
  Licence(const std::string &url, const std::string &key1, const std::string &key2, const std::string &statePath) {
    const char *kids[] = {"k1", "k2"};
    const char *keys[] = {key1.c_str(), key2.c_str()};
    LwConfig cfg{};
    cfg.server_url = url.c_str();
    cfg.key_ids = kids;
    cfg.public_keys = keys;
    cfg.key_count = 2;
    cfg.storage_path = statePath.c_str();
    String error;
    client_.reset(lw_client_new(&cfg, &error.p));
    if (!client_) std::fprintf(stderr, "licence: %s\n", error.str().c_str());
  }

  // From the licence window. Returns an empty string on success, else a message to show.
  std::string activate(const std::string &key) {
    if (!client_) return "not configured";
    Status st;
    String message;
    if (lw_activate(client_.get(), key.c_str(), &st, &message.p) != LW_RESULT_OK) return message.str();
    unlocked_.store(st.unlocked);
    return {};
  }

  // Off the audio thread: at start-up, then now and then.
  void checkInBackground() {
    std::thread([this] {
      if (!client_) return;
      Status st;
      lw_check(client_.get(), &st);
      unlocked_.store(st.unlocked);
    }).join();  // a real plugin keeps the thread and does not join here
  }

  // Safe on the audio thread: no lock, no allocation, no network.
  bool unlocked() const { return unlocked_.load(std::memory_order_relaxed); }

 private:
  struct Free {
    void operator()(LwClient *c) const { lw_client_free(c); }
  };
  std::unique_ptr<LwClient, Free> client_;
  std::atomic<bool> unlocked_{false};
};

}  // namespace lw

int main(int argc, char **argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: plugin_licence <state-file> [key]\n");
    return 2;
  }
  auto env = [](const char *k) { const char *v = std::getenv(k); return std::string(v ? v : ""); };
  lw::Licence licence(env("LW_URL"), env("LW_PUBLIC_KEY_1"), env("LW_PUBLIC_KEY_2"), argv[1]);
  if (argc > 2) {
    std::string err = licence.activate(argv[2]);
    if (!err.empty()) std::printf("activation failed: %s\n", err.c_str());
  }
  licence.checkInBackground();
  std::printf("license-worker %s: %s\n", lw_version(), licence.unlocked() ? "unlocked" : "locked");
  return 0;
}
