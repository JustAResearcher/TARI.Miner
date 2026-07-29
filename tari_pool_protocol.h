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

inline bool json_find_value_impl(
    const std::string &json,
    const char *key,
    size_t &value_position,
    size_t start,
    size_t required_depth
) {
    size_t depth = 0;
    for (size_t i = 0; i < json.size();) {
        char c = json[i];
        if (c == '{' || c == '[') {
            depth++;
            i++;
            continue;
        }
        if (c == '}' || c == ']') {
            if (depth) depth--;
            i++;
            continue;
        }
        if (c != '"') {
            i++;
            continue;
        }

        size_t token_start = ++i;
        bool escaped = false;
        while (i < json.size()) {
            char token_char = json[i];
            if (escaped) {
                escaped = false;
            } else if (token_char == '\\') {
                escaped = true;
            } else if (token_char == '"') {
                break;
            }
            i++;
        }
        if (i == json.size()) return false;
        size_t token_end = i++;
        if (token_start < start ||
            (required_depth && depth != required_depth) ||
            token_end - token_start != std::strlen(key) ||
            json.compare(token_start, token_end - token_start, key) != 0) {
            continue;
        }

        while (i < json.size() &&
               (json[i] == ' ' || json[i] == '\t' ||
                json[i] == '\r' || json[i] == '\n')) {
            i++;
        }
        if (i == json.size() || json[i++] != ':') continue;
        while (i < json.size() &&
               (json[i] == ' ' || json[i] == '\t' ||
                json[i] == '\r' || json[i] == '\n')) {
            i++;
        }
        if (i == json.size()) return false;
        value_position = i;
        return true;
    }
    return false;
}

inline bool json_find_value_from(
    const std::string &json,
    const char *key,
    size_t &value_position,
    size_t start = 0
) {
    return json_find_value_impl(json, key, value_position, start, 0);
}

inline bool json_find_root_value(
    const std::string &json,
    const char *key,
    size_t &value_position
) {
    return json_find_value_impl(json, key, value_position, 0, 1);
}

inline bool json_root_literal(
    const std::string &json,
    const char *key,
    const char *literal
) {
    size_t position = 0;
    if (!json_find_root_value(json, key, position)) return false;
    size_t length = std::strlen(literal);
    if (json.compare(position, length, literal) != 0) return false;
    size_t end = position + length;
    if (end == json.size()) return true;
    char delimiter = json[end];
    return delimiter == ',' || delimiter == '}' || delimiter == ']' ||
           delimiter == ' ' || delimiter == '\t' ||
           delimiter == '\r' || delimiter == '\n';
}

inline bool json_root_uint(
    const std::string &json,
    const char *key,
    uint64_t &value
) {
    size_t position = 0;
    if (!json_find_root_value(json, key, position) ||
        position == json.size() ||
        json[position] < '0' || json[position] > '9') {
        return false;
    }

    uint64_t parsed = 0;
    size_t i = position;
    for (; i < json.size() && json[i] >= '0' && json[i] <= '9'; ++i) {
        unsigned digit = (unsigned)(json[i] - '0');
        if (parsed > (std::numeric_limits<uint64_t>::max() - digit) / 10)
            return false;
        parsed = parsed * 10 + digit;
    }
    if (i < json.size()) {
        char delimiter = json[i];
        if (delimiter != ',' && delimiter != '}' && delimiter != ']' &&
            delimiter != ' ' && delimiter != '\t' &&
            delimiter != '\r' && delimiter != '\n') {
            return false;
        }
    }
    value = parsed;
    return true;
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
