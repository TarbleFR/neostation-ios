// Imported from XITRIX/rpcs3 ios-port, GPL-2.0; upstream v0.10.1 regression fixture.
// Test-only diagnostic adapters: fail fast on production assertions; no emulator lifecycle.
namespace fmt
{
	void raw_append(std::string& out, const char* msg, const fmt_type_info* info, const u64* values) noexcept
	{
		out += msg;
		for (int i = 0; info[i].fmt_string; i++)
			out += " [" + std::to_string(values[i]) + "]";
	}
	[[noreturn]] void raw_verify_error(std::source_location loc, const char8_t*, usz)
	{
		std::cerr << loc.file_name() << ":" << loc.line() << " verification failed\n";
		std::abort();
	}
	[[noreturn]] void raw_range_error(std::source_location loc, usz, usz)
	{
		raw_verify_error(loc, u8"range", 0);
	}
	[[noreturn]] void raw_throw_exception(std::source_location loc, const char* message, const fmt_type_info*, const u64*)
	{
		std::cerr << message << '\n';
		raw_verify_error(loc, u8"exception", 0);
	}
} // namespace fmt
template <>
void fmt_class_string<u32>::format(std::string& out, u64 arg)
{
	out += std::to_string(arg);
}
template <>
void fmt_class_string<u64>::format(std::string& out, u64 arg)
{
	out += std::to_string(arg);
}
#if defined(__APPLE__)
// Darwin's uint64_t is unsigned long long; Linux's is unsigned long.
template <>
void fmt_class_string<unsigned long>::format(std::string& out, u64 arg)
{
	out += std::to_string(arg);
}
#endif
template <>
void fmt_class_string<fmt::base57>::format(std::string& out, u64)
{
	out += "fixture";
}
namespace logs
{
	registerer::registerer(channel&) {}
} // namespace logs
namespace utils
{
	u64 _get_main_tid()
	{
		return 1;
	}
} // namespace utils
