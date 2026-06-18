package testcontainers

// Tight, purpose-built HTTP/1.1 for the Docker API. We only ever need:
//   - serialize a request with an optional body
//   - parse a response: status line, headers, body
//   - decode Content-Length OR Transfer-Encoding: chunked
// Nothing else. Zero dependencies beyond core.

import "core:bytes"
import "core:strconv"
import "core:strings"

Response :: struct {
	status:  int,
	reason:  string,
	headers: map[string]string, // keys lowercased
	body:    []u8,
}

// Build a raw HTTP/1.1 request. `Connection: close` lets read_all terminate on EOF.
@(private)
build_request :: proc(
	method, path: string,
	body: []u8 = nil,
	content_type := "",
	allocator := context.allocator,
) -> []u8 {
	b := strings.builder_make(allocator)
	strings.write_string(&b, method)
	strings.write_byte(&b, ' ')
	strings.write_string(&b, path)
	strings.write_string(&b, " HTTP/1.1\r\n")
	strings.write_string(&b, "Host: localhost\r\n")
	strings.write_string(&b, "Connection: close\r\n")
	if len(body) > 0 {
		if content_type != "" {
			strings.write_string(&b, "Content-Type: ")
			strings.write_string(&b, content_type)
			strings.write_string(&b, "\r\n")
		}
		strings.write_string(&b, "Content-Length: ")
		strings.write_int(&b, len(body))
		strings.write_string(&b, "\r\n")
	}
	strings.write_string(&b, "\r\n")
	if len(body) > 0 {
		strings.write_bytes(&b, body)
	}
	return b.buf[:]
}

// Parse a full raw response buffer. The returned Response owns its memory;
// free it with response_destroy.
@(private)
parse_response :: proc(raw: []u8, allocator := context.allocator) -> (resp: Response, ok: bool) {
	sep := bytes.index(raw, []u8{'\r', '\n', '\r', '\n'})
	if sep < 0 {
		return {}, false
	}
	header_block := string(raw[:sep])
	body_raw := raw[sep + 4:]

	lines := strings.split(header_block, "\r\n", allocator)
	defer delete(lines, allocator)
	if len(lines) == 0 {
		return {}, false
	}

	// Status line: "HTTP/1.1 200 OK" — reason may contain spaces, so split on
	// the first two spaces only.
	status_line := lines[0]
	sp1 := strings.index_byte(status_line, ' ')
	if sp1 < 0 {
		return {}, false
	}
	after := status_line[sp1 + 1:]
	sp2 := strings.index_byte(after, ' ')
	if sp2 < 0 {
		return {}, false
	}
	resp.status, _ = strconv.parse_int(after[:sp2])
	resp.reason = strings.clone(after[sp2 + 1:], allocator)

	// Headers.
	resp.headers = make(map[string]string, allocator)
	chunked := false
	for line in lines[1:] {
		colon := strings.index_byte(line, ':')
		if colon < 0 {
			continue
		}
		key := strings.to_lower(strings.trim_space(line[:colon]), allocator)
		val := strings.clone(strings.trim_space(line[colon + 1:]), allocator)
		resp.headers[key] = val
		if key == "transfer-encoding" && strings.contains(val, "chunked") {
			chunked = true
		}
	}

	// Body.
	if chunked {
		resp.body = decode_chunked(body_raw, allocator) or_return
	} else {
		resp.body = make([]u8, len(body_raw), allocator)
		copy(resp.body, body_raw)
	}
	return resp, true
}

// Decode a chunked body: repeated `<hex-size>[;ext]\r\n<data>\r\n`, ending at a
// zero-size chunk.
@(private)
decode_chunked :: proc(data: []u8, allocator := context.allocator) -> (out: []u8, ok: bool) {
	acc := make([dynamic]u8, 0, len(data), allocator)
	i := 0
	for i < len(data) {
		line_end := bytes.index(data[i:], []u8{'\r', '\n'})
		if line_end < 0 {
			delete(acc)
			return nil, false
		}
		size_str := string(data[i:i + line_end])
		if semi := strings.index_byte(size_str, ';'); semi >= 0 {
			size_str = size_str[:semi] // drop chunk extensions
		}
		n, parsed := strconv.parse_int(size_str, 16)
		if !parsed {
			delete(acc)
			return nil, false
		}
		i += line_end + 2 // past size line CRLF
		if n == 0 {
			break // final chunk
		}
		if i + n > len(data) {
			delete(acc)
			return nil, false
		}
		append(&acc, ..data[i:i + n])
		i += n + 2 // past data + trailing CRLF
	}
	return acc[:], true
}

response_destroy :: proc(resp: ^Response, allocator := context.allocator) {
	for k, v in resp.headers {
		delete(k, allocator)
		delete(v, allocator)
	}
	delete(resp.headers)
	delete(resp.reason, allocator)
	delete(resp.body, allocator)
}
