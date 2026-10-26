#include <jni.h>
#include <libplatform/libplatform.h>
#include <v8.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <map>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace {
constexpr int kMaxProgramBytes = 64 * 1024;
constexpr int kMaxInputBytes = 64 * 1024;
constexpr int kMaxOutputBytes = 64 * 1024;
constexpr int kMaxLogBytes = 16 * 1024;
constexpr int kMaxLogEntries = 128;
// The App controller admits at most five seconds for ordinary scripts. The
// isolated engine carries the private workflow's separate bounded lifetime.
constexpr int kMaxDeadlineMillis = 120000;
constexpr int kMaxHostRequestBytes = 32 * 1024;
// Must match Java: 64 KiB of control characters may expand sixfold in JSON.
constexpr int kMaxHostReplyBytes = 448 * 1024;
constexpr int kMaxGrantsBytes = 8192;
constexpr int kMaxPendingHostCalls = 8;
constexpr int kMaxHostCalls = 128;
constexpr size_t kMaxArrayBufferBytes = 8 * 1024 * 1024;

// Compiled before guest code and held only by native handles, never installed
// on globalThis. It captures intrinsic operations before a script can replace
// them, then detaches plain JSON data without invoking toJSON or getters.
// Keep the traversal limits aligned with the Android PTC contract docs.
constexpr char kSnapshotSource[] = R"PTC_JSON(
(() => {
  const isArray = Array.isArray;
  const getProto = Object.getPrototypeOf;
  const descriptor = Object.getOwnPropertyDescriptor;
  const ownKeys = Reflect.ownKeys;
  const create = Object.create;
  const define = Object.defineProperty;
  const setProto = Object.setPrototypeOf;
  const finite = Number.isFinite;
  const is = Object.is;
  const apply = Reflect.apply;
  const SafeWeakSet = WeakSet;
  const hasOwn = Object.prototype.hasOwnProperty;
  const weakHas = WeakSet.prototype.has;
  const weakAdd = WeakSet.prototype.add;
  const weakDelete = WeakSet.prototype.delete;
  const arrayProto = Array.prototype;
  const objectProto = Object.prototype;
  const toString = String;
  const invalid = Symbol();
  return value => {
    let count = 0;
    const active = new SafeWeakSet();
    const visit = (source, depth) => {
      if (++count > 8192 || depth > 64) return invalid;
      if (source === null || typeof source === 'string' ||
          typeof source === 'boolean') return source;
      if (typeof source === 'number')
        return finite(source) && !is(source, -0) ? source : invalid;
      if (typeof source !== 'object') return invalid;
      if (apply(weakHas, active, [source])) return invalid;
      apply(weakAdd, active, [source]);
      try {
        if (isArray(source)) {
          if (getProto(source) !== arrayProto || source.length > 8192)
            return invalid;
          const keys = ownKeys(source);
          if (keys.length !== source.length + 1 ||
              keys[keys.length - 1] !== 'length') return invalid;
          const copy = [];
          setProto(copy, null);
          for (let index = 0; index < source.length; index++) {
            if (keys[index] !== toString(index)) return invalid;
            const slot = descriptor(source, toString(index));
            if (!slot || !slot.enumerable ||
                !apply(hasOwn, slot, ['value'])) return invalid;
            const item = visit(slot.value, depth + 1);
            if (item === invalid) return invalid;
            define(copy, toString(index), { value: item, enumerable: true,
              configurable: true, writable: true });
          }
          return copy;
        }
        const proto = getProto(source);
        if (proto !== null && proto !== objectProto) return invalid;
        const copy = create(null);
        for (const key of ownKeys(source)) {
          if (typeof key !== 'string') return invalid;
          const slot = descriptor(source, key);
          if (!slot || !slot.enumerable ||
              !apply(hasOwn, slot, ['value'])) return invalid;
          const item = visit(slot.value, depth + 1);
          if (item === invalid) return invalid;
          define(copy, key, { value: item, enumerable: true,
            configurable: true, writable: true });
        }
        return copy;
      } finally {
        apply(weakDelete, active, [source]);
      }
    };
    const copy = visit(value, 0);
    return copy === invalid ? undefined : copy;
  };
})()
)PTC_JSON";

enum class Stop { kNone, kCancelled, kDeadline };
enum class ProgramFormat { kFunctionExpression, kAsyncFunctionBody };

struct Result {
  const char* status;
  std::u16string output;
  std::u16string logs;
};

struct ConsoleCapture {
  std::u16string json = u"[";
  int entries = 0;
  bool overflow = false;
};

void appendJsonString(std::u16string* output, const std::u16string& input) {
  constexpr char16_t hex[] = u"0123456789abcdef";
  output->push_back(u'"');
  for (char16_t value : input) {
    if (value == u'"' || value == u'\\') {
      output->push_back(u'\\');
      output->push_back(value);
    } else if (value < 0x20 || value > 0x7e) {
      output->append(u"\\u");
      output->push_back(hex[(value >> 12) & 15]);
      output->push_back(hex[(value >> 8) & 15]);
      output->push_back(hex[(value >> 4) & 15]);
      output->push_back(hex[value & 15]);
    } else output->push_back(value);
  }
  output->push_back(u'"');
}

void consoleCall(const v8::FunctionCallbackInfo<v8::Value>& args) {
  auto* capture = static_cast<ConsoleCapture*>(
      args.Data().As<v8::External>()->Value());
  if (capture->overflow) return;
  v8::Isolate* isolate = args.GetIsolate();
  auto context = isolate->GetCurrentContext();
  std::u16string line;
  for (int i = 0; i < args.Length(); ++i) {
    v8::Local<v8::String> part;
    if (!args[i]->ToString(context).ToLocal(&part)) return;
    v8::String::Value text(isolate, part);
    if (*text == nullptr) return;
    if (i != 0) line.push_back(u' ');
    line.append(reinterpret_cast<const char16_t*>(*text), text.length());
    if (line.size() > kMaxLogBytes) { capture->overflow = true; return; }
  }
  std::u16string encoded;
  appendJsonString(&encoded, line);
  if (capture->entries >= kMaxLogEntries ||
      encoded.size() + (capture->entries == 0 ? 0 : 1) >
          kMaxLogBytes - capture->json.size() - 1) {
    capture->overflow = true;
    return;
  }
  if (capture->entries++ != 0) capture->json.push_back(u',');
  capture->json.append(encoded);
}

class LimitedArrayBufferAllocator final : public v8::ArrayBuffer::Allocator {
 public:
  void* Allocate(size_t length) override { return allocate(length, true); }
  void* AllocateUninitialized(size_t length) override {
    return allocate(length, false);
  }
  void Free(void* data, size_t length) override {
    std::free(data);
    used_.fetch_sub(length, std::memory_order_relaxed);
  }
  size_t MaxAllocationSize() const override { return kMaxArrayBufferBytes; }

 private:
  void* allocate(size_t length, bool zero) {
    if (length > kMaxArrayBufferBytes) return nullptr;
    size_t current = used_.load(std::memory_order_relaxed);
    while (true) {
      if (current > kMaxArrayBufferBytes - length) return nullptr;
      if (used_.compare_exchange_weak(current, current + length,
                                      std::memory_order_relaxed)) break;
    }
    void* memory = zero ? std::calloc(1, length == 0 ? 1 : length)
                        : std::malloc(length == 0 ? 1 : length);
    if (memory == nullptr) used_.fetch_sub(length, std::memory_order_relaxed);
    return memory;
  }
  std::atomic<size_t> used_{0};
};

class Execution final {
 public:
  struct HostReply { int sequence; std::u16string value; };
  bool begin() {
    std::lock_guard lock(mutex_);
    if (started_ || finished_ || closed_) return false;
    started_ = true;
    return true;
  }
  void stop(Stop reason) {
    std::lock_guard lock(mutex_);
    if (finished_ || stop_ != Stop::kNone) return;
    stop_ = reason;
    if (isolate_ != nullptr) isolate_->TerminateExecution();
    condition_.notify_all();
  }
  Stop reason() {
    std::lock_guard lock(mutex_);
    return stop_;
  }
  bool deliver(int sequence, std::u16string value) {
    std::lock_guard lock(mutex_);
    if (!started_ || finished_ || closed_ || stop_ != Stop::kNone ||
        sequence < 1 || sequence > kMaxHostCalls ||
        replies_.size() >= kMaxPendingHostCalls) return false;
    replies_.push_back({sequence, std::move(value)});
    condition_.notify_all();
    return true;
  }
  bool awaitReply(std::chrono::steady_clock::time_point deadline,
                  HostReply* reply) {
    std::unique_lock lock(mutex_);
    condition_.wait_until(lock, deadline, [this] {
      return !replies_.empty() || stop_ != Stop::kNone || finished_;
    });
    if (stop_ != Stop::kNone || finished_ || replies_.empty()) return false;
    *reply = std::move(replies_.front());
    replies_.pop_front();
    return true;
  }
  void setIsolate(v8::Isolate* isolate) {
    std::lock_guard lock(mutex_);
    isolate_ = isolate;
    if (isolate_ != nullptr && stop_ != Stop::kNone) {
      isolate_->TerminateExecution();
    }
  }
  void finish() {
    std::lock_guard lock(mutex_);
    isolate_ = nullptr;
    finished_ = true;
    condition_.notify_all();
  }
  Stop finishAt(std::chrono::steady_clock::time_point deadline) {
    std::lock_guard lock(mutex_);
    if (stop_ == Stop::kNone && std::chrono::steady_clock::now() >= deadline) {
      stop_ = Stop::kDeadline;
    }
    isolate_ = nullptr;
    finished_ = true;
    condition_.notify_all();
    return stop_;
  }
  void close() {
    std::lock_guard lock(mutex_);
    closed_ = true;
    if (!finished_ && stop_ == Stop::kNone) {
      stop_ = Stop::kCancelled;
      if (isolate_ != nullptr) isolate_->TerminateExecution();
    }
    condition_.notify_all();
  }
  bool canErase() {
    std::lock_guard lock(mutex_);
    return closed_ && (!started_ || finished_);
  }
  void awaitDeadline(std::chrono::steady_clock::time_point deadline) {
    std::unique_lock lock(mutex_);
    if (condition_.wait_until(lock, deadline, [this] {
          return finished_ || stop_ != Stop::kNone;
        })) return;
    stop_ = Stop::kDeadline;
    if (isolate_ != nullptr) isolate_->TerminateExecution();
  }

 private:
  std::mutex mutex_;
  std::condition_variable condition_;
  v8::Isolate* isolate_ = nullptr;
  Stop stop_ = Stop::kNone;
  bool started_ = false;
  bool finished_ = false;
  bool closed_ = false;
  std::deque<HostReply> replies_;
};

struct IsolateGuard {
  std::shared_ptr<Execution> execution;
  v8::Isolate* isolate;
  ~IsolateGuard() {
    execution->setIsolate(nullptr);
    isolate->Dispose();
  }
};

std::mutex registry_mutex;
std::map<jlong, std::shared_ptr<Execution>> registry;
std::atomic<jlong> next_id{1};
std::once_flag initialize_once;
std::unique_ptr<v8::Platform> platform;

std::shared_ptr<Execution> lookup(jlong id) {
  std::lock_guard lock(registry_mutex);
  auto entry = registry.find(id);
  return entry == registry.end() ? nullptr : entry->second;
}

bool denyWasm(v8::Local<v8::Context>, v8::Local<v8::String>) {
  return false;
}

bool denySharedArrayBuffer(v8::Local<v8::Context>) { return false; }

std::u16string fromJava(JNIEnv* env, jstring text) {
  if (text == nullptr) return {};
  const jsize length = env->GetStringLength(text);
  const jchar* characters = env->GetStringChars(text, nullptr);
  if (characters == nullptr) return {};
  std::u16string value(reinterpret_cast<const char16_t*>(characters), length);
  env->ReleaseStringChars(text, characters);
  return value;
}

int utf8Bytes(const std::u16string& value) {
  int bytes = 0;
  for (size_t i = 0; i < value.size(); ++i) {
    const auto code = static_cast<unsigned int>(value[i]);
    if (code < 0x80) ++bytes;
    else if (code < 0x800) bytes += 2;
    else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < value.size() &&
             value[i + 1] >= 0xDC00 && value[i + 1] <= 0xDFFF) {
      bytes += 4;
      ++i;
    } else bytes += 3;
  }
  return bytes;
}

v8::MaybeLocal<v8::String> v8String(v8::Isolate* isolate,
                                    const std::u16string& value) {
  return v8::String::NewFromTwoByte(
      isolate, reinterpret_cast<const uint16_t*>(value.data()),
      v8::NewStringType::kNormal, static_cast<int>(value.size()));
}

struct HostBinding {
  JNIEnv* env;
  jobject callback;
  jmethodID method;
  jmethodID submit;
  std::map<int, v8::Global<v8::Promise::Resolver>> pending;
};

bool encodeHostRequest(const v8::FunctionCallbackInfo<v8::Value>& args,
                       v8::Local<v8::String>* encoded) {
  auto* isolate = args.GetIsolate();
  if (args.Length() != 1 ||
      !v8::JSON::Stringify(isolate->GetCurrentContext(), args[0]).ToLocal(encoded) ||
      (*encoded)->Utf8Length(isolate) > kMaxHostRequestBytes) {
    isolate->ThrowException(v8::Exception::TypeError(
        v8::String::NewFromUtf8Literal(isolate, "Invalid host request")));
    return false;
  }
  return true;
}

void hostCall(const v8::FunctionCallbackInfo<v8::Value>& args) {
  auto* isolate = args.GetIsolate();
  auto context = isolate->GetCurrentContext();
  auto* binding = static_cast<HostBinding*>(
      args.Data().As<v8::External>()->Value());
  if (binding == nullptr) {
    isolate->ThrowException(v8::Exception::TypeError(
        v8::String::NewFromUtf8Literal(isolate, "Expected one host request")));
    return;
  }
  v8::Local<v8::String> encoded;
  if (!encodeHostRequest(args, &encoded)) return;
  v8::String::Value request(isolate, encoded);
  if (*request == nullptr) return;
  jstring java_request = binding->env->NewString(
      reinterpret_cast<const jchar*>(*request), request.length());
  if (java_request == nullptr) return;
  auto java_reply = static_cast<jstring>(binding->env->CallObjectMethod(
      binding->callback, binding->method, java_request));
  binding->env->DeleteLocalRef(java_request);
  if (binding->env->ExceptionCheck()) {
    binding->env->ExceptionClear();
    isolate->ThrowException(v8::Exception::Error(
        v8::String::NewFromUtf8Literal(isolate, "Host request failed")));
    return;
  }
  if (java_reply == nullptr) {
    isolate->ThrowException(v8::Exception::Error(
        v8::String::NewFromUtf8Literal(isolate, "Host reply unavailable")));
    return;
  }
  const std::u16string reply = fromJava(binding->env, java_reply);
  binding->env->DeleteLocalRef(java_reply);
  if (binding->env->ExceptionCheck()) {
    binding->env->ExceptionClear();
    isolate->ThrowException(v8::Exception::Error(
        v8::String::NewFromUtf8Literal(isolate, "Host reply could not be decoded")));
    return;
  }
  if (utf8Bytes(reply) > kMaxHostReplyBytes) {
    isolate->ThrowException(v8::Exception::Error(
        v8::String::NewFromUtf8Literal(isolate, "Host reply too large")));
    return;
  }
  auto reply_text = v8String(isolate, reply);
  v8::Local<v8::Value> parsed;
  if (reply_text.IsEmpty() ||
      !v8::JSON::Parse(context, reply_text.ToLocalChecked()).ToLocal(&parsed)) return;
  args.GetReturnValue().Set(parsed);
}

void hostCallAsync(const v8::FunctionCallbackInfo<v8::Value>& args) {
  auto* isolate = args.GetIsolate();
  auto context = isolate->GetCurrentContext();
  auto* binding = static_cast<HostBinding*>(args.Data().As<v8::External>()->Value());
  if (binding == nullptr || binding->callback == nullptr ||
      binding->pending.size() >= kMaxPendingHostCalls) {
    isolate->ThrowException(v8::Exception::Error(
        v8::String::NewFromUtf8Literal(isolate, "Host request limit reached")));
    return;
  }
  v8::Local<v8::String> encoded;
  if (!encodeHostRequest(args, &encoded)) return;
  auto resolver = v8::Promise::Resolver::New(context);
  if (resolver.IsEmpty()) return;
  v8::String::Value request(isolate, encoded);
  if (*request == nullptr) return;
  jstring java_request = binding->env->NewString(
      reinterpret_cast<const jchar*>(*request), request.length());
  if (java_request == nullptr) return;
  jint sequence = binding->env->CallIntMethod(
      binding->callback, binding->submit, java_request);
  binding->env->DeleteLocalRef(java_request);
  if (binding->env->ExceptionCheck()) {
    binding->env->ExceptionClear();
    isolate->ThrowException(v8::Exception::Error(
        v8::String::NewFromUtf8Literal(isolate, "Host request failed")));
    return;
  }
  if (sequence < 1 || sequence > kMaxHostCalls || binding->pending.count(sequence)) {
    isolate->ThrowException(v8::Exception::Error(
        v8::String::NewFromUtf8Literal(isolate, "Invalid host sequence")));
    return;
  }
  binding->pending.emplace(sequence,
      v8::Global<v8::Promise::Resolver>(isolate, resolver.ToLocalChecked()));
  args.GetReturnValue().Set(resolver.ToLocalChecked()->GetPromise());
}

Result execute(const std::shared_ptr<Execution>& execution,
               const std::u16string& program, const std::u16string& input,
               JNIEnv* env, jobject host_callback,
               const std::u16string& grants,
               std::chrono::steady_clock::time_point deadline,
               ProgramFormat format) {
  std::call_once(initialize_once, [] {
    platform = v8::platform::NewDefaultPlatform(1);
    v8::V8::InitializePlatform(platform.get());
    v8::V8::Initialize();
  });
  if (execution->reason() != Stop::kNone) return {"CANCELLED", {}};

  auto allocator = std::make_shared<LimitedArrayBufferAllocator>();
  v8::Isolate::CreateParams parameters;
  parameters.array_buffer_allocator_shared = allocator;
  parameters.allow_atomics_wait = false;
  parameters.constraints.set_max_old_generation_size_in_bytes(16 * 1024 * 1024);
  parameters.constraints.set_max_young_generation_size_in_bytes(4 * 1024 * 1024);
  v8::Isolate* isolate = v8::Isolate::New(parameters);
  if (isolate == nullptr) return {"ENGINE_UNAVAILABLE", {}};
  IsolateGuard isolate_guard{execution, isolate};
  execution->setIsolate(isolate);
  Result result{"SCRIPT_ERROR", {}};
  {
    v8::Isolate::Scope isolate_scope(isolate);
    v8::HandleScope handle_scope(isolate);
    isolate->SetMicrotasksPolicy(v8::MicrotasksPolicy::kExplicit);
    isolate->SetAllowWasmCodeGenerationCallback(denyWasm);
    isolate->SetSharedArrayBufferConstructorEnabledCallback(
        denySharedArrayBuffer);
    v8::TryCatch errors(isolate);
    auto context = v8::Context::New(isolate);
    if (!context.IsEmpty()) {
      v8::Context::Scope context_scope(context);
      context->AllowCodeGenerationFromStrings(false);
      auto snapshot_text = v8::String::NewFromUtf8(isolate, kSnapshotSource);
      v8::Local<v8::Script> snapshot_script;
      v8::Local<v8::Value> snapshot_value;
      if (snapshot_text.IsEmpty() ||
          !v8::Script::Compile(context, snapshot_text.ToLocalChecked())
               .ToLocal(&snapshot_script) ||
          !snapshot_script->Run(context).ToLocal(&snapshot_value) ||
          !snapshot_value->IsFunction()) {
        return {"ENGINE_UNAVAILABLE", {}};
      }
      auto snapshot = snapshot_value.As<v8::Function>();
      auto input_text = v8String(isolate, input);
      v8::Local<v8::Value> parsed_input;
      if (input_text.IsEmpty() ||
          !v8::JSON::Parse(context, input_text.ToLocalChecked())
               .ToLocal(&parsed_input)) {
        result.status = "INVALID_INPUT";
      } else {
        v8::Local<v8::Value> host_value = v8::Undefined(isolate);
        HostBinding binding{env, host_callback, nullptr, nullptr, {}};
        ConsoleCapture captured_logs;
        if (host_callback != nullptr) {
          jclass callback_class = env->GetObjectClass(host_callback);
          if (callback_class == nullptr) return {"ENGINE_UNAVAILABLE", {}};
          binding.method = env->GetMethodID(callback_class, "call",
                                            "(Ljava/lang/String;)Ljava/lang/String;");
          binding.submit = env->GetMethodID(callback_class, "submit",
                                            "(Ljava/lang/String;)I");
          env->DeleteLocalRef(callback_class);
          if (binding.method == nullptr || binding.submit == nullptr) {
            env->ExceptionClear();
            return {"ENGINE_UNAVAILABLE", {}};
          }
          auto grants_text = v8String(isolate, grants);
          v8::Local<v8::Value> parsed_grants;
          if (grants_text.IsEmpty() ||
              !v8::JSON::Parse(context, grants_text.ToLocalChecked())
                   .ToLocal(&parsed_grants) || !parsed_grants->IsArray()) {
            return {"INVALID_REQUEST", {}};
          }
          auto host = v8::Object::New(isolate);
          auto call = v8::Function::New(
              context, hostCall, v8::External::New(isolate, &binding));
          auto call_async = v8::Function::New(
              context, hostCallAsync, v8::External::New(isolate, &binding));
          if (call.IsEmpty() || call_async.IsEmpty() ||
              !host->Set(context, v8::String::NewFromUtf8Literal(isolate, "call"),
                         call.ToLocalChecked()).FromMaybe(false) ||
              !host->Set(context, v8::String::NewFromUtf8Literal(isolate, "callAsync"),
                         call_async.ToLocalChecked()).FromMaybe(false) ||
              !host->Set(context, v8::String::NewFromUtf8Literal(isolate, "grants"),
                         parsed_grants).FromMaybe(false) ||
              !host->SetIntegrityLevel(context, v8::IntegrityLevel::kFrozen)
                   .FromMaybe(false)) {
            return {"ENGINE_UNAVAILABLE", {}};
          }
          host_value = host;
        }
        auto console = v8::Object::New(isolate);
        bool console_ready = true;
        for (const char* method : {"log", "info", "warn", "error", "debug"}) {
          auto name = v8::String::NewFromUtf8(isolate, method).ToLocalChecked();
          auto callback = v8::Function::New(context, consoleCall,
              v8::External::New(isolate, &captured_logs));
          if (callback.IsEmpty() ||
              !console->Set(context, name, callback.ToLocalChecked()).FromMaybe(false)) {
            console_ready = false;
            break;
          }
        }
        if (!console_ready ||
            !console->SetIntegrityLevel(context, v8::IntegrityLevel::kFrozen)
                 .FromMaybe(false) ||
            !context->Global()->DefineOwnProperty(context,
                v8::String::NewFromUtf8Literal(isolate, "console"), console,
                static_cast<v8::PropertyAttribute>(v8::ReadOnly | v8::DontDelete))
                 .FromMaybe(false)) {
          return {"ENGINE_UNAVAILABLE", {}};
        }
        v8::Local<v8::Function> function;
        if (format == ProgramFormat::kAsyncFunctionBody) {
          // Only this trusted constructor invocation may generate code from a
          // string. The untrusted body is a separate argument, not interpolated
          // into an enclosing source expression. Disable code generation again
          // before calling any user code or passing the App-issued host object.
          auto ctor_source = v8::String::NewFromUtf8Literal(
              isolate, "(async function(){}).constructor");
          v8::Local<v8::Script> ctor_script;
          v8::Local<v8::Value> ctor_value;
          if (!v8::Script::Compile(context, ctor_source).ToLocal(&ctor_script) ||
              !ctor_script->Run(context).ToLocal(&ctor_value) ||
              !ctor_value->IsFunction()) {
            result.status = "ENGINE_UNAVAILABLE";
          } else {
            std::u16string strict_body = u"'use strict';\n";
            strict_body += program;
            auto body_source = v8String(isolate, strict_body);
            if (body_source.IsEmpty()) {
              result.status = "INVALID_PROGRAM";
            } else {
              v8::Local<v8::Value> ctor_args[] = {
                  v8::String::NewFromUtf8Literal(isolate, "input"),
                  v8::String::NewFromUtf8Literal(isolate, "host"),
                  body_source.ToLocalChecked()};
              v8::Local<v8::Object> constructed;
              context->AllowCodeGenerationFromStrings(true);
              bool created = ctor_value.As<v8::Function>()
                  ->NewInstance(context, 3, ctor_args).ToLocal(&constructed);
              context->AllowCodeGenerationFromStrings(false);
              if (!created || !constructed->IsFunction()) {
                result.status = "INVALID_PROGRAM";
              } else function = constructed.As<v8::Function>();
            }
          }
        } else {
          std::u16string expression = u"(";
          expression += program;
          expression += u")";
          auto source = v8String(isolate, expression);
          v8::Local<v8::Script> compiled;
          v8::Local<v8::Value> function_value;
          if (source.IsEmpty() ||
              !v8::Script::Compile(context, source.ToLocalChecked())
                   .ToLocal(&compiled) ||
              !compiled->Run(context).ToLocal(&function_value) ||
              !function_value->IsFunction()) {
            result.status = "INVALID_PROGRAM";
          } else function = function_value.As<v8::Function>();
        }
        if (function.IsEmpty()) {
          // The script parser rejected the program, or the trusted constructor
          // could not be initialized. No user function has been invoked.
        } else {
          v8::Local<v8::Value> arguments[] = {parsed_input, host_value};
          v8::Local<v8::Value> value;
          if (function->Call(context, context->Global(), 2, arguments)
                  .ToLocal(&value)) {
            isolate->PerformMicrotaskCheckpoint();
            bool serializable = true;
            if (value->IsPromise()) {
              auto promise = value.As<v8::Promise>();
              while (promise->State() == v8::Promise::kPending &&
                     !binding.pending.empty() && execution->reason() == Stop::kNone) {
                Execution::HostReply reply;
                if (!execution->awaitReply(deadline, &reply)) break;
                auto pending = binding.pending.find(reply.sequence);
                if (pending == binding.pending.end() ||
                    utf8Bytes(reply.value) > kMaxHostReplyBytes) {
                  result.status = "SCRIPT_ERROR";
                  serializable = false;
                  break;
                }
                auto reply_text = v8String(isolate, reply.value);
                v8::Local<v8::Value> parsed_reply;
                if (reply_text.IsEmpty() ||
                    !v8::JSON::Parse(context, reply_text.ToLocalChecked())
                         .ToLocal(&parsed_reply) ||
                    !pending->second.Get(isolate)->Resolve(context, parsed_reply)
                         .FromMaybe(false)) {
                  result.status = "SCRIPT_ERROR";
                  serializable = false;
                  break;
                }
                binding.pending.erase(pending);
                isolate->PerformMicrotaskCheckpoint();
              }
              if (serializable && promise->State() == v8::Promise::kPending) {
                result.status = "ASYNC_HOST_UNAVAILABLE";
                serializable = false;
              } else if (serializable && promise->State() == v8::Promise::kRejected) {
                result.status = "SCRIPT_ERROR";
                serializable = false;
              } else if (serializable) {
                value = promise->Result();
              }
            }
            if (serializable && !binding.pending.empty()) {
              result.status = "ASYNC_HOST_UNAVAILABLE";
              serializable = false;
            }
            if (serializable && !errors.HasCaught()) {
              v8::Local<v8::Value> arguments[] = {value};
              v8::Local<v8::Value> detached;
              if (!snapshot->Call(context, v8::Undefined(isolate), 1, arguments)
                       .ToLocal(&detached) || detached->IsUndefined()) {
                result.status = "OUTPUT_INVALID";
              } else {
                v8::Local<v8::String> serialized;
                if (!v8::JSON::Stringify(context, detached).ToLocal(&serialized)) {
                  result.status = "OUTPUT_INVALID";
                } else {
                  if (captured_logs.overflow) {
                    result.status = "OUTPUT_TOO_LARGE";
                  } else {
                    captured_logs.json.push_back(u']');
                    if (captured_logs.json.size() > kMaxLogBytes ||
                        serialized->Utf8Length(isolate) +
                            captured_logs.json.size() > kMaxOutputBytes) {
                      result.status = "OUTPUT_TOO_LARGE";
                    } else {
                      v8::String::Value characters(isolate, serialized);
                      if (*characters != nullptr) {
                        result = {"COMPLETED",
                            std::u16string(reinterpret_cast<const char16_t*>(*characters),
                                           characters.length()),
                            std::move(captured_logs.json)};
                      } else result.status = "ENGINE_UNAVAILABLE";
                    }
                  }
                }
              }
            }
          }
        }
      }
    } else result.status = "ENGINE_UNAVAILABLE";
  }
  return result;
}

jobjectArray toJava(JNIEnv* env, const Result& result) {
  jclass string_class = env->FindClass("java/lang/String");
  if (string_class == nullptr) return nullptr;
  jobjectArray pair = env->NewObjectArray(3, string_class, nullptr);
  if (pair == nullptr) return nullptr;
  jstring status = env->NewStringUTF(result.status);
  jstring output = env->NewString(
      reinterpret_cast<const jchar*>(result.output.data()),
      static_cast<jsize>(result.output.size()));
  jstring logs = env->NewString(
      reinterpret_cast<const jchar*>(result.logs.data()),
      static_cast<jsize>(result.logs.size()));
  if (status == nullptr || output == nullptr || logs == nullptr) return nullptr;
  env->SetObjectArrayElement(pair, 0, status);
  env->SetObjectArrayElement(pair, 1, output);
  env->SetObjectArrayElement(pair, 2, logs);
  env->DeleteLocalRef(status);
  env->DeleteLocalRef(output);
  env->DeleteLocalRef(logs);
  return pair;
}
}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_minnnng_dsh_1android_PtcScriptEngine_nativeCreate(JNIEnv*, jclass) {
  std::lock_guard lock(registry_mutex);
  if (!registry.empty()) return 0;  // One guest execution at a time.
  const jlong id = next_id.fetch_add(1);
  registry.emplace(id, std::make_shared<Execution>());
  return id;
}

extern "C" JNIEXPORT void JNICALL
Java_com_minnnng_dsh_1android_PtcScriptEngine_nativeCancel(
    JNIEnv*, jclass, jlong id) {
  auto execution = lookup(id);
  if (execution != nullptr) execution->stop(Stop::kCancelled);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_minnnng_dsh_1android_PtcScriptEngine_nativeDeliverReply(
    JNIEnv* env, jclass, jlong id, jint sequence, jstring reply_text) {
  auto execution = lookup(id);
  if (execution == nullptr || reply_text == nullptr ||
      env->GetStringLength(reply_text) > kMaxHostReplyBytes) return JNI_FALSE;
  std::u16string reply = fromJava(env, reply_text);
  if (env->ExceptionCheck()) { env->ExceptionClear(); return JNI_FALSE; }
  if (utf8Bytes(reply) > kMaxHostReplyBytes) return JNI_FALSE;
  return execution->deliver(sequence, std::move(reply)) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_minnnng_dsh_1android_PtcScriptEngine_nativeClose(
    JNIEnv*, jclass, jlong id) {
  auto execution = lookup(id);
  if (execution == nullptr) return;
  execution->close();
  if (execution->canErase()) {
    std::lock_guard lock(registry_mutex);
    auto entry = registry.find(id);
    if (entry != registry.end() && entry->second == execution) registry.erase(entry);
  }
}

static jobjectArray runNative(
    JNIEnv* env, jlong id, jstring program_text, jstring input_text,
    jint deadline_millis, jobject host_callback, jstring grants_text,
    ProgramFormat format) {
  auto execution = lookup(id);
  if (execution == nullptr || !execution->begin()) {
    return toJava(env, {"INVALID_EXECUTION", {}});
  }
  if (program_text == nullptr || input_text == nullptr ||
      (host_callback == nullptr) != (grants_text == nullptr) ||
      env->GetStringLength(program_text) > kMaxProgramBytes ||
      env->GetStringLength(input_text) > kMaxInputBytes ||
      (grants_text != nullptr && env->GetStringLength(grants_text) > kMaxGrantsBytes) ||
      deadline_millis < 1 || deadline_millis > kMaxDeadlineMillis) {
    execution->finish();
    return toJava(env, {"INVALID_REQUEST", {}});
  }
  std::u16string program;
  std::u16string input;
  std::u16string grants;
  try {
    program = fromJava(env, program_text);
    input = fromJava(env, input_text);
    if (grants_text != nullptr) grants = fromJava(env, grants_text);
  } catch (...) {
    execution->finish();
    return toJava(env, {"ENGINE_UNAVAILABLE", {}});
  }
  if (utf8Bytes(program) > kMaxProgramBytes ||
      utf8Bytes(input) > kMaxInputBytes ||
      (grants_text != nullptr && utf8Bytes(grants) > kMaxGrantsBytes)) {
    execution->finish();
    return toJava(env, {"INVALID_REQUEST", {}});
  }
  const auto deadline = std::chrono::steady_clock::now() +
      std::chrono::milliseconds(deadline_millis);
  std::thread watchdog;
  try {
    watchdog = std::thread([execution, deadline] {
      execution->awaitDeadline(deadline);
    });
  } catch (...) {
    execution->finish();
    return toJava(env, {"ENGINE_UNAVAILABLE", {}});
  }
  Result result{"ENGINE_UNAVAILABLE", {}};
  try {
    result = execute(execution, program, input, env, host_callback, grants,
                     deadline, format);
  } catch (...) {
    result = {"ENGINE_UNAVAILABLE", {}};
  }
  const Stop reason = execution->finishAt(deadline);
  watchdog.join();
  if (execution->canErase()) {
    std::lock_guard lock(registry_mutex);
    auto entry = registry.find(id);
    if (entry != registry.end() && entry->second == execution) registry.erase(entry);
  }
  if (reason == Stop::kDeadline) result = {"DEADLINE_EXCEEDED", {}};
  else if (reason == Stop::kCancelled) result = {"CANCELLED", {}};
  return toJava(env, result);
}

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_minnnng_dsh_1android_PtcScriptEngine_nativeRun(
    JNIEnv* env, jclass, jlong id, jstring program_text, jstring input_text,
    jint deadline_millis, jobject host_callback, jstring grants_text) {
  return runNative(env, id, program_text, input_text, deadline_millis,
                   host_callback, grants_text, ProgramFormat::kFunctionExpression);
}

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_minnnng_dsh_1android_PtcScriptEngine_nativeRunFunctionBody(
    JNIEnv* env, jclass, jlong id, jstring body_text, jstring input_text,
    jint deadline_millis, jobject host_callback, jstring grants_text) {
  return runNative(env, id, body_text, input_text, deadline_millis,
                   host_callback, grants_text, ProgramFormat::kAsyncFunctionBody);
}
