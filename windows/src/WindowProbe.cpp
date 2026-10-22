// Windows 10/11, C++17. Read-only: no UI text, config contents or command lines.
#include <windows.h>
#include <tlhelp32.h>
#include <wincrypt.h>
#include <wintrust.h>
#include <softpub.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cwchar>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace {
// --- Handles, JSON and executable paths ---

// Close an owned process or snapshot handle when it leaves scope.
class Handle {
 public:
  explicit Handle(HANDLE value) : value_(value) {}
  ~Handle() { if (value_ && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  HANDLE get() const { return value_; }
 private:
  HANDLE value_;
};
// Convert UTF-16 text to an escaped UTF-8 JSON string.
std::string Json(const std::wstring& value) {
  if (value.empty()) return "\"\"";
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (!size) return "\"[unavailable]\"";
  std::string utf8(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
      utf8.data(), size, nullptr, nullptr);
  std::string result = "\"";
  for (unsigned char ch : utf8) {
    if (ch == '"' || ch == '\\') { result += '\\'; result += static_cast<char>(ch); }
    else if (ch < 0x20) {
      char escaped[7]; std::snprintf(escaped, sizeof(escaped), "\\u%04x", ch);
      result += escaped;
    } else result += static_cast<char>(ch);
  }
  return result + '"';
}
std::wstring Basename(const std::wstring& path) {
  const auto last = path.find_last_of(L"\\/");
  return last == std::wstring::npos ? path : path.substr(last + 1);
}
// Match candidate executable names from Chromium remoting/host/win/BUILD.gn.
bool CandidateName(const std::wstring& name) {
  return _wcsicmp(name.c_str(), L"remoting_host.exe") == 0 ||
         _wcsicmp(name.c_str(), L"remoting_desktop.exe") == 0;
}
// Resolve an optional executable filter to an absolute path, or return an empty string.
std::wstring FullPath(const std::wstring& input) {
  std::vector<wchar_t> buffer(32768);
  const DWORD count = GetFullPathNameW(input.c_str(), static_cast<DWORD>(buffer.size()), buffer.data(), nullptr);
  return count && count < buffer.size() ? std::wstring(buffer.data(), count) : L"";
}
// Read a process image path without reading its command line or loading its code.
std::wstring ImagePath(HANDLE process) {
  std::vector<wchar_t> buffer(32768); DWORD count = static_cast<DWORD>(buffer.size());
  return QueryFullProcessImageNameW(process, 0, buffer.data(), &count) ? std::wstring(buffer.data(), count) : L"";
}
// --- Candidate signature and process identity ---

// Keep the trust result separate from the embedded signer's display-name match.
struct Signature { bool trusted = false; bool google = false; LONG status = TRUST_E_NOSIGNATURE; };
// Check cached Authenticode trust and the embedded signer without UI or network requests.
Signature CheckSignature(const std::wstring& path) {
  Signature result;
  WINTRUST_FILE_INFO file{}; file.cbStruct = sizeof(file); file.pcwszFilePath = path.c_str();
  WINTRUST_DATA trust{}; trust.cbStruct = sizeof(trust); trust.dwUIChoice = WTD_UI_NONE;
  trust.fdwRevocationChecks = WTD_REVOKE_NONE; trust.dwUnionChoice = WTD_CHOICE_FILE;
  trust.pFile = &file; trust.dwStateAction = WTD_STATEACTION_VERIFY;
  // Cache-only chain lookup; no trust UI or online revocation request.
  trust.dwProvFlags = WTD_CACHE_ONLY_URL_RETRIEVAL;
  GUID policy = WINTRUST_ACTION_GENERIC_VERIFY_V2;
  result.status = WinVerifyTrust(nullptr, &policy, &trust);
  result.trusted = result.status == ERROR_SUCCESS;
  trust.dwStateAction = WTD_STATEACTION_CLOSE; WinVerifyTrust(nullptr, &policy, &trust);
  HCERTSTORE store = nullptr; HCRYPTMSG message = nullptr;
  if (CryptQueryObject(CERT_QUERY_OBJECT_FILE, path.c_str(),
      CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED, CERT_QUERY_FORMAT_FLAG_BINARY,
      0, nullptr, nullptr, nullptr, &store, &message, nullptr)) {
    DWORD size = 0;
    if (CryptMsgGetParam(message, CMSG_SIGNER_INFO_PARAM, 0, nullptr, &size) && size) {
      std::vector<unsigned char> bytes(size);
      if (CryptMsgGetParam(message, CMSG_SIGNER_INFO_PARAM, 0, bytes.data(), &size)) {
        const auto* signer = reinterpret_cast<const CMSG_SIGNER_INFO*>(bytes.data());
        CERT_INFO info{}; info.Issuer = signer->Issuer; info.SerialNumber = signer->SerialNumber;
        PCCERT_CONTEXT cert = CertFindCertificateInStore(store, X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
            0, CERT_FIND_SUBJECT_CERT, &info, nullptr);
        if (cert) {
          wchar_t display[512]{};
          const DWORD copied = CertGetNameStringW(cert, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, nullptr, display, 512);
          result.google = result.trusted && copied > 1 &&
              (_wcsicmp(display, L"Google LLC") == 0 || _wcsicmp(display, L"Google Inc") == 0 || _wcsicmp(display, L"Google Inc.") == 0);
          CertFreeCertificateContext(cert);
        }
      }
    }
  }
  if (message) CryptMsgClose(message);
  if (store) CertCloseStore(store, 0);
  return result;
}
// Describe a candidate executable, using process creation time to distinguish reused PIDs.
struct Process {
  DWORD pid = 0; FILETIME created{}; std::wstring basename;
  bool pathReadable = false; Signature signature;
};
std::wstring exactPath;
std::map<DWORD, Process> processes;
// Validate the executable filter and reuse signature results only for the same process birth.
bool QueryCandidate(DWORD pid, Process* output) {
  Handle handle(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid));
  if (!handle.get()) return false;
  const auto path = ImagePath(handle.get());
  if (path.empty() || !CandidateName(Basename(path)) ||
      (!exactPath.empty() && _wcsicmp(exactPath.c_str(), path.c_str()) != 0)) return false;
  FILETIME created{}, exited{}, kernel{}, user{};
  if (!GetProcessTimes(handle.get(), &created, &exited, &kernel, &user)) return false;
  const auto found = processes.find(pid);
  if (found != processes.end() && CompareFileTime(&found->second.created, &created) == 0) {
    *output = found->second; return true;
  }
  Process item; item.pid = pid; item.created = created; item.basename = Basename(path);
  item.pathReadable = true; item.signature = CheckSignature(path);
  processes[pid] = item; *output = item; return true;
}
// Emit candidate identity and signature fields without exposing the full executable path.
void PrintProcess(const Process& process) {
  const auto name = Json(process.basename);
  const char* identity = process.signature.google ? "google-signed-file-candidate" : "basename-candidate";
  std::printf("{\"kind\":\"candidate-process\",\"pid\":%lu,\"executable\":%s,\"candidate\":true,\"identity\":\"%s\",\"imagePathReadable\":%s,\"authenticodeTrusted\":%s,\"googleSignerDisplayNameMatched\":%s,\"signatureStatus\":%ld}\n",
      process.pid, name.c_str(), identity, process.pathReadable ? "true" : "false",
      process.signature.trusted ? "true" : "false", process.signature.google ? "true" : "false", process.signature.status);
}
// --- Window observations and snapshots ---

// Store only a window's process ID, visibility and available bounds.
struct Window {
  DWORD pid = 0; bool visible = false; bool boundsKnown = false; RECT rect{};
};
std::map<HWND, Window> windows;
// Compare observable window state so duplicate events can be suppressed.
bool SameWindow(const Window& a, const Window& b) {
  return a.pid == b.pid && a.visible == b.visible && a.boundsKnown == b.boundsKnown &&
      (!a.boundsKnown || EqualRect(&a.rect, &b.rect));
}
// Emit a candidate window event without reading its title or UI text.
void PrintWindow(HWND hwnd, const Window& window, const char* event) {
  char handle[32]; std::snprintf(handle, sizeof(handle), "0x%llx",
      static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(hwnd)));
  std::printf("{\"kind\":\"candidate-window\",\"event\":\"%s\",\"candidate\":true,\"hwnd\":\"%s\",\"pid\":%lu,\"visible\":%s,\"boundsKnown\":%s",
      event, handle, window.pid, window.visible ? "true" : "false", window.boundsKnown ? "true" : "false");
  if (window.boundsKnown) std::printf(",\"frame\":{\"left\":%ld,\"top\":%ld,\"width\":%ld,\"height\":%ld}",
      window.rect.left, window.rect.top, window.rect.right - window.rect.left, window.rect.bottom - window.rect.top);
  std::printf("}\n");
}
// Record a validated candidate window and emit only its initial or changed state.
void Observe(HWND hwnd, const char* event, bool initial) {
  DWORD pid = 0; GetWindowThreadProcessId(hwnd, &pid);
  Process process;
  if (!pid || !QueryCandidate(pid, &process)) return;
  if (windows.find(hwnd) == windows.end() && !initial) PrintProcess(process);
  Window item; item.pid = pid; item.visible = IsWindowVisible(hwnd) != FALSE;
  item.boundsKnown = GetWindowRect(hwnd, &item.rect) != FALSE;
  const auto found = windows.find(hwnd);
  // Duplicate WinEvents do not produce repeated identical window records.
  if (found == windows.end() || !SameWindow(found->second, item) || initial) PrintWindow(hwnd, item, event);
  windows[hwnd] = item;
}
BOOL CALLBACK EnumerateWindow(HWND hwnd, LPARAM) { Observe(hwnd, "snapshot", true); return TRUE; }
// Enumerate accessible candidate processes and top-level windows, reporting incomplete queries.
bool Snapshot() {
  Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
  size_t inaccessibleNamedCandidates = 0;
  bool processEnumerationSucceeded = false;
  if (snapshot.get() != INVALID_HANDLE_VALUE) {
    PROCESSENTRY32W entry{}; entry.dwSize = sizeof(entry);
    if (Process32FirstW(snapshot.get(), &entry)) {
      processEnumerationSucceeded = true;
      do {
        if (!CandidateName(entry.szExeFile)) continue;
        Process candidate;
        if (QueryCandidate(entry.th32ProcessID, &candidate)) PrintProcess(candidate);
        else ++inaccessibleNamedCandidates;
      } while (Process32NextW(snapshot.get(), &entry));
    }
  }
  const BOOL enumerated = EnumWindows(EnumerateWindow, 0);
  std::printf("{\"kind\":\"snapshot-summary\",\"candidateProcesses\":%llu,\"candidateWindows\":%llu,\"unresolvedOrFilteredNamedProcesses\":%llu,\"processEnumerationSucceeded\":%s,\"enumerationSucceeded\":%s,\"sharingSessionConfirmed\":false}\n",
      static_cast<unsigned long long>(processes.size()), static_cast<unsigned long long>(windows.size()),
      static_cast<unsigned long long>(inaccessibleNamedCandidates), processEnumerationSucceeded ? "true" : "false", enumerated ? "true" : "false");
  std::fflush(stdout);
  return processEnumerationSucceeded && enumerated != FALSE;
}
// --- Event-driven observation and shutdown ---

// Update candidate state for top-level window events and discard destroyed window records.
void CALLBACK WinEvent(HWINEVENTHOOK, DWORD event, HWND hwnd, LONG object, LONG child, DWORD, DWORD) {
  if (!hwnd || object != OBJID_WINDOW || child != CHILDID_SELF) return;
  if (event == EVENT_OBJECT_DESTROY) {
    const auto found = windows.find(hwnd);
    if (found != windows.end()) { Window last = found->second; last.visible = false; last.boundsKnown = false;
      PrintWindow(hwnd, last, "destroyed"); windows.erase(found); }
  } else if (event == EVENT_OBJECT_CREATE || event == EVENT_OBJECT_SHOW || event == EVENT_OBJECT_HIDE || event == EVENT_OBJECT_LOCATIONCHANGE) {
    if (GetAncestor(hwnd, GA_ROOT) != hwnd) return;
    Observe(hwnd, event == EVENT_OBJECT_CREATE ? "created" : event == EVENT_OBJECT_SHOW ? "shown" : event == EVENT_OBJECT_HIDE ? "hidden" : "bounds-changed", false);
  }
  std::fflush(stdout);
}
DWORD watchThread = 0;
// Stop only this diagnostic's message loop when its console receives an exit signal.
BOOL WINAPI ConsoleControl(DWORD event) {
  if (event == CTRL_C_EVENT || event == CTRL_BREAK_EVENT || event == CTRL_CLOSE_EVENT) {
    PostThreadMessageW(watchThread, WM_QUIT, 0, 0); return TRUE;
  }
  return FALSE;
}
}  // namespace
// Parse the executable filter and emit one snapshot or observe events until shutdown.
int wmain(int argc, wchar_t** argv) {
  bool watch = false;
  for (int i = 1; i < argc; ++i) {
    if (std::wcscmp(argv[i], L"--watch") == 0) watch = true;
    else if (std::wcscmp(argv[i], L"--once") == 0) watch = false;
    else if (std::wcscmp(argv[i], L"--exe-path") == 0 && i + 1 < argc) {
      exactPath = FullPath(argv[++i]); if (exactPath.empty()) return 2;
    } else {
      std::fprintf(stderr, "Usage: CRDWindowProbe [--once|--watch] [--exe-path <exact local CRD executable>]\n"); return 2;
    }
  }
  if (!watch) return Snapshot() ? 0 : 1;
  watchThread = GetCurrentThreadId(); MSG message{};
  PeekMessageW(&message, nullptr, WM_USER, WM_USER, PM_NOREMOVE);  // Create our own message queue.
  HWINEVENTHOOK hook = SetWinEventHook(EVENT_OBJECT_CREATE, EVENT_OBJECT_LOCATIONCHANGE,
      nullptr, WinEvent, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
  if (!hook) { std::fprintf(stderr, "SetWinEventHook failed (%lu); no settings changed.\n", GetLastError()); return 1; }
  if (!SetConsoleCtrlHandler(ConsoleControl, TRUE)) {
    UnhookWinEvent(hook); std::fprintf(stderr, "Console handler unavailable; watch not started.\n"); return 1;
  }
  Snapshot();
  std::printf("{\"kind\":\"watch-ready\",\"readOnly\":true,\"eventDriven\":true}\n"); std::fflush(stdout);
  BOOL result;
  while ((result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
    TranslateMessage(&message); DispatchMessageW(&message);
  }
  UnhookWinEvent(hook); SetConsoleCtrlHandler(ConsoleControl, FALSE);
  return result == -1 ? 1 : 0;
}
