// RPCS3-local state: nested emission must restore its caller's write mode.
// pthread's switch is per thread, so LLVM workers must enter their own scope.
bool write_protected() noexcept;
void write_protect(bool executable) noexcept;

class write_guard
{
	const bool m_previous = write_protected();
public:
	write_guard() noexcept { write_protect(false); }
	~write_guard() noexcept { write_protect(m_previous); }
	write_guard(const write_guard&) = delete;
	write_guard& operator=(const write_guard&) = delete;
};
