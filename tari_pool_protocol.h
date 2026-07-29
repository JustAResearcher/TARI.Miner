// Small, GPU-independent pool protocol and socket lifecycle helpers.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <mutex>
#include <string>
#include <utility>

namespace tari_pool {

constexpr size_t MAX_LINE_BYTES = 1u << 20;
constexpr size_t MAX_TERMINAL_TEXT = 4096;

inline int hex_value(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

inline bool target_hex_to_diff(const std::string &target_hex, uint64_t &diff) {
    diff = 0;
    if (target_hex.size() != 16) return false;

    uint64_t target = 0;
    for (int i = 7; i >= 0; --i) {
        int hi = hex_value(target_hex[2 * i]);
        int lo = hex_value(target_hex[2 * i + 1]);
        if (hi < 0 || lo < 0) return false;
        target = (target << 8) | (uint64_t)((hi << 4) | lo);
    }

    if (target == 0) {
        diff = std::numeric_limits<uint64_t>::max();
        return true;
    }
    diff = std::numeric_limits<uint64_t>::max() / target;
    if (diff == 0) diff = 1;
    return true;
}

inline std::string sanitize_for_terminal(
    const std::string &text,
    size_t max_length = MAX_TERMINAL_TEXT
) {
    size_t length = text.size() < max_length ? text.size() : max_length;
    std::string safe;
    safe.reserve(length + (text.size() > max_length ? 3 : 0));
    for (size_t i = 0; i < length; ++i) {
        unsigned char c = (unsigned char)text[i];
        safe.push_back(c < 0x20 || (c >= 0x7f && c <= 0x9f) ? '.' : (char)c);
    }
    if (text.size() > max_length) safe += "...";
    return safe;
}

class LineBuffer {
public:
    template <typename Handler>
    bool append(const char *data, size_t length, Handler &&handler) {
        size_t offset = 0;
        while (offset < length) {
            const char *newline = static_cast<const char *>(
                std::memchr(data + offset, '\n', length - offset)
            );
            size_t segment_length = newline
                ? (size_t)(newline - (data + offset))
                : length - offset;
            if (segment_length > MAX_LINE_BYTES - buffer_.size()) return false;
            buffer_.append(data + offset, segment_length);

            if (!newline) return true;
            if (!buffer_.empty() && buffer_.back() == '\r') buffer_.pop_back();
            handler(buffer_);
            buffer_.clear();
            offset += segment_length + 1;
        }
        return true;
    }

    size_t size() const {
        return buffer_.size();
    }

private:
    std::string buffer_;
};

template <typename Socket, Socket Invalid>
class SocketState {
public:
    SocketState() = default;
    SocketState(const SocketState &) = delete;
    SocketState &operator=(const SocketState &) = delete;

    void set(Socket socket) {
        std::lock_guard<std::mutex> lock(send_mutex_);
        socket_.store(socket);
    }

    Socket load() const {
        return socket_.load();
    }

    template <typename Sender>
    bool with_socket(Sender &&sender) {
        std::lock_guard<std::mutex> lock(send_mutex_);
        Socket socket = socket_.load();
        if (socket == Invalid) return false;
        return std::forward<Sender>(sender)(socket);
    }

    template <typename Shutdown, typename Join, typename Close>
    void stop(Shutdown &&shutdown, Join &&join, Close &&close) {
        Socket socket;
        {
            std::lock_guard<std::mutex> lock(send_mutex_);
            socket = socket_.exchange(Invalid);
        }
        if (socket != Invalid) std::forward<Shutdown>(shutdown)(socket);
        std::forward<Join>(join)();
        if (socket != Invalid) std::forward<Close>(close)(socket);
    }

private:
    std::atomic<Socket> socket_{Invalid};
    mutable std::mutex send_mutex_;
};

} // namespace tari_pool
