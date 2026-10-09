-- scripts/regress-test-names.lua — regression tests for Go test/bench name
-- detection (dev.test._nearest_func), incl. underscores in identifiers.
--
-- Run:  nvim --headless --noplugin -u NONE \
--          --cmd "set rtp+=<repo-root>" -l scripts/regress-test-names.lua
-- Exit 0 when all cases pass, 1 otherwise. No network, no user config.
--
-- NOTE: must run with `-l` (no user init). Uses only vim.api + dev.test.

local failures = 0
local total = 0

local function check(desc, cond)
	total = total + 1
	if cond then
		print("OK " .. desc)
	else
		failures = failures + 1
		print("FAIL " .. desc)
	end
end

local T = require("dev.test")

local fixture = {
	"package scratch",
	"",
	"import \"testing\"",
	"",
	"func helperNotATest(x int) int {",
	"\tif x > 0 {",
	"\t\treturn x",
	"\t}",
	"\treturn -x",
	"}",
	"",
	"func TestPlain(t *testing.T) {",
	'\tt.Log("plain")',
	"}",
	"",
	"func TestBigIntCodec_RoundTrip(t *testing.T) {",
	"\tf := func() int {",
	"\t\ty := 0",
	"\t\tfor i := 0; i < 3; i++ {",
	"\t\t\ty += i",
	"\t\t}",
	"\t\treturn y",
	"\t}()",
	"\tif f != 3 {",
	'\t\tt.Fatalf("got %d", f)',
	"\t}",
	"}",
	"",
	"func TestA_B_C_D(t *testing.T) {",
	'\tt.Log("multi")',
	"}",
	"",
	"func BenchmarkPlain(b *testing.B) {",
	"\tfor i := 0; i < b.N; i++ {",
	"\t\t_ = i",
	"\t}",
	"}",
	"",
	"func BenchmarkCodec_Encode_Simd(b *testing.B) {",
	"\tfor i := 0; i < b.N; i++ {",
	"\t\t_ = i",
	"\t}",
	"}",
	"",
	"type Suite struct{}",
	"",
	"func (s *Suite) TestSuite_Method(t *testing.T) {",
	'\tt.Log("suite")',
	"}",
	"",
	"func TestBelow(t *testing.T) {",
	'\tt.Log("below")',
	"}",
}

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, fixture)
vim.bo[buf].filetype = "go"

---@param line integer 1-based cursor line
---@param kind "test"|"bench"
---@param want string? expected name
---@param want_method boolean expected receiver flag
local function at(line, kind, want, want_method)
	vim.api.nvim_win_set_cursor(0, { line, 0 })
	local got, ism
	if kind == "test" then
		got, ism = T.nearest_test()
	else
		got, ism = T.nearest_bench()
	end
	ism = ism or false
	check(
		string.format("%s@L%d -> %s/%s", kind, line, tostring(want), tostring(want_method)),
		got == want and ism == want_method
	)
end

-- Helpers and blanks above everything must not match.
at(6, "test", nil, false)
at(11, "test", nil, false)
-- Plain test, incl. body and surrounding blanks.
at(12, "test", "TestPlain", false)
at(13, "test", "TestPlain", false)
at(15, "test", "TestPlain", false)
-- Single underscore: decl line, nested closure, deep nesting, tail.
at(16, "test", "TestBigIntCodec_RoundTrip", false)
at(17, "test", "TestBigIntCodec_RoundTrip", false)
at(20, "test", "TestBigIntCodec_RoundTrip", false)
at(26, "test", "TestBigIntCodec_RoundTrip", false)
-- Multiple underscores.
at(29, "test", "TestA_B_C_D", false)
-- Plain benchmark.
at(33, "bench", "BenchmarkPlain", false)
at(35, "bench", "BenchmarkPlain", false)
-- Underscore benchmark.
at(39, "bench", "BenchmarkCodec_Encode_Simd", false)
at(41, "bench", "BenchmarkCodec_Encode_Simd", false)
-- Asking for a test on a benchmark decl line finds the previous test.
at(39, "test", "TestA_B_C_D", false)
-- Receiver method with underscore.
at(47, "test", "TestSuite_Method", true)
at(50, "test", "TestSuite_Method", true)
-- Function below the cursor is never selected.
at(51, "test", "TestBelow", false)

-- Go-regexp escaping for -run/-bench names: identifiers pass through
-- byte-identical (esp. underscore — Lua-style %_ means literal % in Go
-- and used to produce false "all green" via "[no tests to run]"),
-- while RE2 metacharacters get a backslash.
check("escape plain", T._go_escape("TestPlain") == "TestPlain")
check("escape underscores", T._go_escape("TestA_B_C_D") == "TestA_B_C_D")
check("escape dots", T._go_escape("a.b") == "a\\.b")
check("escape parens", T._go_escape("a(b)") == "a\\(b\\)")

print(string.format("total=%d failures=%d", total, failures))
if failures > 0 then
	os.exit(1)
end
