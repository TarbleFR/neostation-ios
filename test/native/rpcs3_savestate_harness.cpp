// SPDX-License-Identifier: GPL-3.0-or-later
// Portable adapters around the ACTUAL patched RPCS3 serialization methods.
// Not a PS3 execution/device test. ZSTD itself is real, not mocked.
#include <algorithm>
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <functional>
#include <iostream>
#include <limits>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>
#define ZSTD_STATIC_LINKING_ONLY
#include <zstd.h>
using u8 = unsigned char;
using u32 = unsigned int;
using usz = std::size_t;
constexpr usz umax = std::numeric_limits<usz>::max();
using namespace std::literals;
#define ensure(x) do { if (!(x)) throw std::runtime_error(#x); } while (0)
namespace fmt {
template<class... T> std::string format(const char* s, T...) { return s; }
[[noreturn]] void throw_exception(const char* s) { throw std::runtime_error(s); }
}
template<class T> using atomic_t = std::atomic<T>;
namespace stx {
template<class T> using shared_ptr = std::shared_ptr<T>;
constexpr std::nullptr_t null_ptr = nullptr;
template<class T, class... A> auto make_single(A&&... a) { return std::make_shared<T>(std::forward<A>(a)...); }
template<class T> auto make_single_value(T&& a) { return std::make_shared<std::decay_t<T>>(std::forward<T>(a)); }
}
using stx::make_single;
template<class T> class atomic_ptr {
  std::shared_ptr<T> value;
  mutable std::mutex mutex;
  std::condition_variable condition;
public:
  explicit operator bool() const { std::lock_guard lock(mutex); return bool(value); }
  void store(std::shared_ptr<T> p) { std::lock_guard lock(mutex); value = p; }
  auto exchange(std::shared_ptr<T> p) { std::lock_guard lock(mutex); return std::exchange(value, p); }
  bool compare_and_swap_test(std::shared_ptr<T> expected, std::shared_ptr<T> next) {
    std::lock_guard lock(mutex);
    if (value != expected) return false;
    value = next;
    return true;
  }
  void wait(std::nullptr_t) { std::unique_lock lock(mutex); condition.wait(lock, [&] { return bool(value); }); }
  void notify_all() { condition.notify_all(); }
};
template<class F> class named_thread {
  std::thread thread;
public:
  template<class S> named_thread(S, F f) : thread(std::move(f)) {}
  void operator()() { if (thread.joinable()) thread.join(); }
  ~named_thread() { (*this)(); }
};
namespace thread_ctrl {
void wait_for(int us) { std::this_thread::sleep_for(std::chrono::microseconds(us)); }
}
namespace rpcs3::ios {
usz get_savestate_compression_thread_limit(usz) { return 3; }
}
namespace fs {
struct file {
  mutable std::vector<u8> bytes;
  usz max_write = umax;
  usz fail_at = umax;
  mutable usz sync_count = 0;
  explicit operator bool() const { return true; }
  usz write(const void* data, usz count) const {
    if (bytes.size() >= fail_at) return 0;
    count = std::min({count, max_write, fail_at - bytes.size()});
    auto p = static_cast<const u8*>(data);
    bytes.insert(bytes.end(), p, p + count);
    return count;
  }
  usz read_at(usz offset, void* data, usz count) const {
    count = std::min(count, bytes.size() - std::min(offset, bytes.size()));
    if (count) std::memcpy(data, bytes.data() + offset, count);
    return count;
  }
  usz size() const { return bytes.size(); }
  void sync() const { ++sync_count; }
};
}
namespace utils {
usz get_thread_count() { return 4; }
template<class T> T sub_saturate(T a, T b) { return a > b ? a-b : 0; }
struct serial {
  std::vector<u8> data;
  usz data_offset = 0, pos = 0, m_max_data = umax;
  bool writing = true, little = false;
  bool is_writing() const { return writing; }
  bool expect_little_data() const { return little; }
  void seek_end() { pos = data_offset + data.size(); }
};
struct serialization_file_handler {
  virtual ~serialization_file_handler() = default;
  virtual bool handle_file_op(serial&, usz, usz, const void*) = 0;
  virtual usz get_size(const serial&, usz) const = 0;
  virtual void skip_until(serial&) = 0;
  virtual bool is_valid() const = 0;
  virtual void finalize(serial&) = 0;
};
}
static int live_decoders = 0;
ZSTD_DCtx* tracked_create() {
  auto p = ZSTD_createDCtx();
  if (p) ++live_decoders;
  return p;
}
size_t tracked_free(ZSTD_DCtx* p) {
  if (p) --live_decoders;
  return ZSTD_freeDCtx(p);
}
#define ZSTD_createDCtx tracked_create
#define ZSTD_freeDCtx tracked_free
#include "NeoStationSavestateIO.h"
#include "NeoStationSavestateStatus.h"

// INSERT_PRODUCTION_SERIALIZATION

static std::vector<u8> fixture() {
  // Mixture of repeated pages, zeros, and deterministic dense data.
  std::vector<u8> data(4 * 1024 * 1024 + 379);
  u32 state = 654321;
  for (usz i = 0; i < data.size(); ++i) {
    state ^= state << 13; state ^= state >> 17; state ^= state << 5;
    data[i] = (i / 4096) % 4 == 0 ? state & 255 : (i / 16384) % 17;
  }
  return data;
}
static void feed(compressed_zstd_serialization_file_handler& handler, utils::serial& ar,
                 const std::vector<u8>& data) {
  for (usz offset = 0; offset < data.size(); offset += 131071) {
    const usz count = std::min<usz>(131071, data.size() - offset);
    ar.data.assign(data.begin() + offset, data.begin() + offset + count);
    ar.seek_end();
    ensure(handler.handle_file_op(ar, 0, umax, nullptr));
  }
}
static void check_read(const fs::file& file, const std::vector<u8>& expected, bool finalize) {
  {
    compressed_zstd_serialization_file_handler reader(file);
    utils::serial ar;
    ar.writing = false;
    for (usz offset = 0; offset < expected.size(); offset += 32768) {
      const usz count = std::min<usz>(32768, expected.size() - offset);
      ar.pos = offset;
      ensure(reader.handle_file_op(ar, offset, count, nullptr));
      ensure(ar.data_offset + ar.data.size() >= offset + count);
      ensure(std::memcmp(ar.data.data() + offset - ar.data_offset, expected.data() + offset, count) == 0);
      ensure(reader.is_valid());
    }
    if (finalize) { reader.finalize(ar); reader.finalize(ar); }
  }
  ensure(live_decoders == 0);
}
int main() {
  const auto data = fixture();
  fs::file good;
  good.max_write = 113; // Real partial-write retry, including every frame header.
  {
    compressed_zstd_serialization_file_handler writer(good);
    for (int repeat = 0; repeat < 4; ++repeat) {
      good.bytes.clear();
      utils::serial ar;
      feed(writer, ar, data);
      writer.finalize(ar);
      writer.finalize(ar);
      ensure(writer.is_valid());
      check_read(good, data, repeat % 2);
    }
  }
  for (int i = 0; i < 1000; ++i) {
    compressed_zstd_serialization_file_handler reader(good);
    utils::serial header;
    header.writing = false;
    header.little = true;
    ensure(reader.handle_file_op(header, 0, 32, nullptr));
    ensure(live_decoders == 1);
  }
  ensure(live_decoders == 0);
  for (usz limit : {usz{0}, usz{57}, usz{100000}}) {
    fs::file broken;
    broken.fail_at = limit;
    broken.max_write = 79;
    compressed_zstd_serialization_file_handler writer(broken);
    utils::serial ar;
    feed(writer, ar, data);
    writer.finalize(ar); // Recoverable failure; must not terminate a native thread.
    ensure(!writer.is_valid());
    ensure(broken.bytes.size() <= limit);
  }
  using namespace neostation::savestate;
  {
    fs::file corrupt = good;
    corrupt.bytes[0] ^= 255;
    compressed_zstd_serialization_file_handler reader(corrupt);
    utils::serial ar;
    ar.writing = false;
    reader.handle_file_op(ar, 0, 64, nullptr);
    ensure(!reader.is_valid());
  }
  ensure(live_decoders == 0);
  operation transaction;
  std::atomic<int> accepted{0};
  std::vector<std::thread> threads;
  for (int i = 0; i < 16; ++i) threads.emplace_back([&] { if (transaction.begin()) ++accepted; });
  for (auto& thread : threads) thread.join();
  ensure(accepted == 1 && transaction.read().active);
  transaction.advance(phase::writing);
  ensure(!transaction.begin());
  transaction.record_write(false);
  ensure(!transaction.read().committed);
  transaction.finish(false, "write failed");
  ensure(transaction.read().state == phase::failed && !transaction.read().message.empty());
  ensure(transaction.begin());
  transaction.record_write(true);
  transaction.advance(phase::restarting);
  ensure(!transaction.begin());
  transaction.finish(true);
  ensure(transaction.read().committed && transaction.read().state == phase::succeeded);
  ensure(transaction.read().message.empty());
  transaction.finish(false, "stale");
  ensure(transaction.read().state == phase::succeeded);
  ensure(transaction.begin());
  transaction.finish(false, "unsafe point");
  ensure(!transaction.read().active && transaction.read().message == "unsafe point");

  // Check historical level-8 files using the same production reader; then
  // report lossless level-3 vs level-8 host timings, NOT iPhone FPS estimates.
  for (int level : {8, compression_level}) {
    fs::file encoded;
    encoded.bytes.resize(ZSTD_compressBound(data.size()));
    const auto start = std::chrono::steady_clock::now();
    usz size = ZSTD_compress(encoded.bytes.data(), encoded.bytes.size(), data.data(), data.size(), level);
    const auto ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    ensure(!ZSTD_isError(size));
    encoded.bytes.resize(size);
    check_read(encoded, data, true);
    std::cout << "Lossless synthetic host compression: level=" << level << " bytes=" << size << " ms=" << ms << '\n';
  }
  std::cout << "PASS: actual RPCS3 ZSTD methods: partial writes, failed writes/drain, repeated writes, "
               "level-8/3 round trips, 1000 decoder lifetimes; native operation exclusivity.\n";
}
