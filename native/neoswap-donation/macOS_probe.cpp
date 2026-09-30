#include "Broker.h"
#include "Pool.h"

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#if defined(NEOSWAP_DONATION_ROUTING_PROBE)
#include "NeoSwap.h"
#include "NeoSwapHost.h"
extern "C" void NeoSwap_TestFailNext(int stage);
#endif

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(__APPLE__) && TARGET_OS_OSX
#include <mach/mach.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {
using namespace neostation::donation;
constexpr std::uint64_t bytes = 64ULL * 1024 * 1024;
constexpr std::uint64_t tolerance = 4ULL * 1024 * 1024;
constexpr std::uint32_t magic = 0x4e53444e;
enum Phase : std::uint32_t { ready = 1, inspect, disconnect, reply };
struct Packet {
  mach_msg_header_t header{};
  mach_msg_body_t body{};
  mach_msg_port_descriptor_t ports[2]{};
  std::uint32_t tag = magic;
  std::uint32_t phase = 0;
  std::uint64_t pid = 0;
  std::uint64_t capacity = bytes;
  std::uint64_t checksum = 0;
  Footprint before{}, after{};
};
struct Buffer {
  Packet packet;
  // Leave space for the Mach security/audit trailer; never receive into a
  // message buffer that is shorter than its trailer allocation.
  unsigned char trailer[MAX_TRAILER_SIZE]{};
};

bool check(Result result, const char* operation) {
  if (result) return true;
  std::fprintf(stderr, "FAIL %s stage=%s kernel=%d missing=%s\n", operation,
      stage_name(result.stage), result.kernel_result,
      result.missing_symbol ? result.missing_symbol : "none");
  return false;
}
bool check(bool value, const char* operation) {
  if (!value) std::fprintf(stderr, "FAIL %s\n", operation);
  return value;
}
std::uint64_t fill(void* data, std::uint64_t seed) {
  auto* words = static_cast<volatile std::uint64_t*>(data);
  std::uint64_t hash = 1469598103934665603ULL;
  for (std::size_t i = 0; i < bytes / sizeof(std::uint64_t); ++i) {
    seed ^= seed << 13;
    seed ^= seed >> 7;
    seed ^= seed << 17;
    words[i] = seed;
    hash = (hash ^ seed) * 1099511628211ULL;
  }
  return hash;
}
std::uint64_t checksum(const void* data) {
  auto* words = static_cast<const volatile std::uint64_t*>(data);
  std::uint64_t hash = 1469598103934665603ULL;
  for (std::size_t i = 0; i < bytes / sizeof(std::uint64_t); ++i)
    hash = (hash ^ words[i]) * 1099511628211ULL;
  return hash;
}
void print(const char* phase, pid_t pid, const Footprint& value) {
  std::printf("{\"phase\":\"%s\",\"pid\":%ld,\"physical\":%" PRIu64
      ",\"resident\":%" PRIu64 ",\"internal\":%" PRIu64
      ",\"nonvolatile\":%" PRIu64 ",\"nonvolatileCompressed\":%" PRIu64 "}\n",
      phase, static_cast<long>(pid), value.physical, value.resident,
      value.internal, value.nonvolatile, value.nonvolatile_compressed);
  std::fflush(stdout);
}
bool send(mach_port_t destination, Packet& packet, bool rights = false) {
  packet.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) |
      (rights ? MACH_MSGH_BITS_COMPLEX : 0);
  packet.header.msgh_size = sizeof(Packet);
  packet.header.msgh_remote_port = destination;
  packet.header.msgh_local_port = MACH_PORT_NULL;
  packet.header.msgh_id = magic;
  packet.body.msgh_descriptor_count = rights ? 2 : 0;
  return check(mach_msg(&packet.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
      sizeof(Packet), 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL) == KERN_SUCCESS,
      "Mach send");
}
bool receive(mach_port_t port, Packet& out) {
  Buffer buffer{};
  const auto kr = mach_msg(&buffer.packet.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
      0, sizeof(buffer), port, 10000, MACH_PORT_NULL);
  if (!check(kr == KERN_SUCCESS, "Mach receive")) return false;
  if (buffer.packet.header.msgh_size != sizeof(Packet) ||
      buffer.packet.tag != magic || buffer.packet.header.msgh_id != magic) {
    mach_msg_destroy(&buffer.packet.header);
    return check(false, "Mach message contract");
  }
  out = buffer.packet;
  return true;
}
mach_port_t receive_port() {
  mach_port_t port = MACH_PORT_NULL;
  if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS)
    return MACH_PORT_NULL;
  if (mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
    mach_port_destroy(mach_task_self(), port);
    return MACH_PORT_NULL;
  }
  return port;
}

int donor() {
  // macOS test bootstrap only: inherited registered send rights are documented
  // in XNU task.defs/ipc_tt.c. iOS integration uses NSExtension auxiliary XPC,
  // never fork or mach_ports_register to launch the helper.
  mach_port_array_t registered = nullptr;
  mach_msg_type_number_t count = 0;
  if (!check(mach_ports_lookup(mach_task_self(), &registered, &count) == KERN_SUCCESS,
             "child registered rights") || !check(count && registered[0], "child host port"))
    return 1;
  mach_port_t host = registered[0];
  for (mach_msg_type_number_t i = 1; i < count; ++i)
    if (registered[i]) mach_port_deallocate(mach_task_self(), registered[i]);
  vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(registered),
                count * sizeof(mach_port_t));
  mach_port_t control = receive_port();
  if (!check(control != MACH_PORT_NULL, "child control port")) return 1;
  Block block;
  Packet first;
  first.phase = ready;
  first.pid = getpid();
  if (!check(footprint(first.before), "donor baseline") ||
      !check(Block::create_owned(bytes, block), "donor create NONVOLATILE")) return 1;
  first.checksum = fill(block.data(), 0x79bdec143abULL);
  if (!check(footprint(first.after), "donor touched footprint")) return 1;
  first.ports[0].name = block.entry();
  first.ports[1].name = control;
  for (auto& descriptor : first.ports) {
    descriptor.disposition = MACH_MSG_TYPE_COPY_SEND;
    descriptor.type = MACH_MSG_PORT_DESCRIPTOR;
  }
  if (!send(host, first, true)) return 1;
  for (;;) {
    Packet request;
    if (!receive(control, request)) return 1;
    if (!check(request.phase == inspect || request.phase == disconnect,
               "child command")) return 1;
    Packet response;
    response.phase = reply;
    response.pid = getpid();
    response.checksum = checksum(block.data());
    if (!check(footprint(response.after), "donor updated footprint") ||
        !send(host, response)) return 1;
    if (request.phase == disconnect) break;
  }
  mach_port_destroy(mach_task_self(), control);
  mach_port_deallocate(mach_task_self(), host);
  return check(block.reset(), "donor release own mapping") ? 0 : 1;
}

bool scenario(std::uint64_t generation, bool abrupt) {
  mach_port_t host = receive_port();
  if (!check(host != MACH_PORT_NULL, "host receive port")) return false;
  mach_port_array_t old = nullptr;
  mach_msg_type_number_t old_count = 0;
  if (!check(mach_ports_lookup(mach_task_self(), &old, &old_count) == KERN_SUCCESS,
             "save registered rights")) return false;
  mach_port_t slots[3] = {host, MACH_PORT_NULL, MACH_PORT_NULL};
  if (!check(mach_ports_register(mach_task_self(), slots, 3) == KERN_SUCCESS,
             "register child bootstrap")) return false;
  const pid_t child = fork();
  if (child == 0) _exit(donor());
  const auto restore = mach_ports_register(mach_task_self(), old, old_count);
  for (mach_msg_type_number_t i = 0; i < old_count; ++i)
    if (old[i]) mach_port_deallocate(mach_task_self(), old[i]);
  if (old) vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(old),
                        old_count * sizeof(mach_port_t));
  if (!check(child > 0, "fork macOS donor") ||
      !check(restore == KERN_SUCCESS, "restore registered rights")) return false;
  bool child_alive = true;
  // From this point every error terminates only this known test child.
  bool success = [&] {
    Packet initial;
    if (!receive(host, initial)) return false;
    if (!check(initial.phase == ready && initial.pid == static_cast<std::uint64_t>(child) &&
               initial.body.msgh_descriptor_count == 2 &&
               initial.capacity == bytes, "donor identity/rights/size")) {
      mach_msg_destroy(&initial.header);
      return false;
    }
    mach_port_t entry = initial.ports[0].name;
    mach_port_t control = initial.ports[1].name;
    Footprint host_before, host_after;
    if (!check(footprint(host_before), "host baseline") ||
        !check(pool_begin(generation, child, bytes), "pool begin") ||
        !check(pool_adopt(generation, entry, bytes), "pool adopt")) return false;
    // Mapping alone must not enable donation or count a game allocation.
    void* address = nullptr;
    std::uint64_t token = 0;
    if (!check(!pool_acquire(bytes, 65536, &address, &token), "unverified pool rejects loans") ||
        !check(pool_verified(generation, initial.after), "pool verify ledgers")) return false;
#if defined(NEOSWAP_DONATION_ROUTING_PROBE)
    char path[] = "/tmp/neoswap-donation-files.XXXXXX";
    if (!check(mkdtemp(path) != nullptr, "file fallback directory")) return false;
    NeoSwapConfig config{};
    config.struct_size = sizeof(config);
    config.abi_version = NEOSWAP_ABI;
    config.capacity_bytes = 2 * bytes;
    config.minimum_allocation_bytes = 1024 * 1024;
    config.enabled_owner_mask = 1u << NEOSWAP_RPCS3;
    // First prove that an actual donor does not depend on the file arena.
    NeoSwap_TestFailNext(6);
    if (!check(NeoSwap_Configure(path, &config) == NEOSWAP_MAPPING,
               "file arena failure is explicit") ||
        !check(NeoSwap_GetAPI(1)->enabled(NEOSWAP_RPCS3) != 0,
               "donor enables RPCS3 despite failed file arena") ||
        !check(NeoSwap_GetAPI(1)->allocate(NEOSWAP_RPCS3, NEOSWAP_CPU_DATA,
            bytes, 65536, &address) == NEOSWAP_OK, "production RPCS3 donor allocation")) return false;
    NeoSwapStats initial_stats{};
    initial_stats.struct_size = sizeof(initial_stats);
    NeoSwapHostStats initial_host{};
    if (!check(NeoSwap_Snapshot(&initial_stats) == NEOSWAP_OK &&
               NeoSwap_HostSnapshot(&initial_host) == NEOSWAP_OK &&
               initial_stats.live_bytes == bytes && initial_stats.allocated_disk_bytes == 0 &&
               initial_host.donated_live_bytes == bytes && initial_host.reserved_virtual_bytes == 0,
               "real donation counts without file reservation")) return false;
#else
    if (!check(pool_acquire(bytes, 65536, &address, &token), "pool real shared loan")) return false;
#endif
    if (!check(!pool_begin(generation + 100, child, bytes),
               "new donor generation refused while a pointer is borrowed")) return false;
    mach_port_deallocate(mach_task_self(), entry);
    if (!check(checksum(address) == initial.checksum, "host reads donor pages")) return false;
    const auto host_hash = fill(address, 0xcb987224c11ULL);
    if (!check(footprint(host_after), "host after shared writes")) return false;
    Packet command;
    command.phase = inspect;
    if (!send(control, command)) return false;
    Packet updated;
    if (!receive(host, updated) ||
        !check(updated.phase == reply && updated.pid == static_cast<std::uint64_t>(child) &&
               updated.checksum == host_hash, "donor reads host writes")) return false;
    print("donor_before", child, initial.before);
    print("donor_after_host_writes", child, updated.after);
    print("host_before", getpid(), host_before);
    print("host_after_shared_writes", getpid(), host_after);
    const auto donor_charge = updated.after.nonvolatile + updated.after.nonvolatile_compressed;
    const auto donor_before_charge = initial.before.nonvolatile + initial.before.nonvolatile_compressed;
    if (!check(donor_charge >= donor_before_charge &&
               donor_charge - donor_before_charge >= bytes - tolerance,
               "real pages charged to donor nonvolatile ledgers") ||
        !check(host_after.physical <= host_before.physical + tolerance,
               "shared pages excluded from host footprint")) return false;
    if (abrupt) {
      if (!check(kill(child, SIGKILL) == 0, "terminate known donor")) return false;
    } else {
      command.phase = disconnect;
      if (!send(control, command) || !receive(host, updated)) return false;
    }
    int status = 0;
    const auto waited = waitpid(child, &status, 0);
    if (waited == child) child_alive = false;
    if (!check(waited == child, "donor termination observed") ||
        !check(abrupt ? WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL :
                       WIFEXITED(status) && WEXITSTATUS(status) == 0,
               "donor exit status")) return false;
    pool_lost(generation, abrupt ? SIGKILL : 0);
    void* rejected = nullptr;
    std::uint64_t rejected_token = 0;
    if (!check(!pool_acquire(4096, 65536, &rejected, &rejected_token),
               "lost donor rejects new loans") ||
        !check(checksum(address) == host_hash, "live pages survive helper death")) return false;
#if defined(NEOSWAP_DONATION_ROUTING_PROBE)
    if (!check(NeoSwap_GetAPI(1)->sync(address) == NEOSWAP_OK &&
               NeoSwap_GetAPI(1)->release(address) == NEOSWAP_OK,
               "production donor sync/release after helper death") ||
        !check(NeoSwap_GetAPI(1)->release(address) == NEOSWAP_NOT_OWNED,
               "production stale release rejected") ||
        !check(NeoSwap_Configure(path, &config) == NEOSWAP_OK,
               "file arena recovery")) return false;
    void* fallback = nullptr;
    if (!check(NeoSwap_GetAPI(1)->allocate(NEOSWAP_RPCS3, NEOSWAP_CPU_DATA,
               1024 * 1024, 65536, &fallback) == NEOSWAP_OK,
               "donor loss falls back to actual file allocation")) return false;
    NeoSwapStats fallback_stats{};
    fallback_stats.struct_size = sizeof(fallback_stats);
    NeoSwapHostStats fallback_host{};
    if (!check(NeoSwap_Snapshot(&fallback_stats) == NEOSWAP_OK &&
               NeoSwap_HostSnapshot(&fallback_host) == NEOSWAP_OK &&
               fallback_stats.allocated_disk_bytes >= 1024 * 1024 &&
               fallback_host.donated_live_bytes == 0, "file fallback is not a donation") ||
        !check(NeoSwap_GetAPI(1)->release(fallback) == NEOSWAP_OK,
               "release file fallback")) return false;
    config.capacity_bytes = 0;
    if (!check(NeoSwap_Configure(path, &config) == NEOSWAP_OK && rmdir(path) == 0,
               "close production allocator and temporary directory")) return false;
#else
    if (!check(pool_release(token), "release live loan after helper death") ||
        !check(!pool_release(token), "stale release rejected")) return false;
#endif
    mach_port_deallocate(mach_task_self(), control);
    return true;
  }();
  if (!success && child_alive) {
    kill(child, SIGKILL);
    int status = 0;
    waitpid(child, &status, 0);
  }
  mach_port_destroy(mach_task_self(), host);
  return success;
}
}  // namespace

int main() {
  using namespace neostation::donation;
  if (!check(availability(), "Darwin API availability")) return 77;
#if defined(NEOSWAP_TESTING)
  void* quarantined = nullptr;
  {
    Block retiring;
    if (!check(Block::create_owned(1024 * 1024, retiring), "real cleanup test object")) return 1;
    quarantined = retiring.data();
    *static_cast<volatile std::uint64_t*>(quarantined) = 0x732cb987;
    test_fail_next_unmaps(1);
  }
  CleanupSnapshot cleanup{};
  cleanup_snapshot(cleanup);
  if (!check(cleanup.pending_blocks == 1 && cleanup.pending_mappings == 1 &&
             cleanup.pending_rights == 1 && cleanup.last_stage == Stage::unmap &&
             *static_cast<volatile std::uint64_t*>(quarantined) == 0x732cb987,
             "failed destructor retains actual mapping and send right") ||
      !check(retry_cleanup(), "retry quarantined kernel resources")) return 1;
  cleanup_snapshot(cleanup);
  if (!check(!cleanup.pending_blocks && !cleanup.pending_mappings &&
             !cleanup.pending_rights, "cleanup retry releases retained resources")) return 1;
#endif
  Footprint before, touched;
  if (!check(footprint(before), "anonymous positive-control baseline")) return 1;
  void* control = mmap(nullptr, bytes, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANON, -1, 0);
  if (!check(control != MAP_FAILED, "anonymous positive-control allocation")) return 1;
  (void)fill(control, 0x123987a3ULL);
  if (!check(footprint(touched), "anonymous positive-control footprint")) return 1;
  print("positive_control_before", getpid(), before);
  print("positive_control_touched", getpid(), touched);
  if (!check(touched.physical >= before.physical &&
             touched.physical - before.physical >= bytes - tolerance,
             "anonymous pages charge host")) return 1;
  if (!check(munmap(control, bytes) == 0, "release positive control")) return 1;
  if (!scenario(1, false) || !scenario(2, true)) return 1;
  std::puts("PASS real shared NONVOLATILE pages, donor attribution, bidirectional checksums, clean disconnect and abrupt donor death");
  return 0;
}
#else
int main() {
  std::fputs("UNSUPPORTED: Darwin macOS multiprocess probe requires a macOS SDK and kernel; no donation result.\n", stderr);
  return 77;
}
#endif
