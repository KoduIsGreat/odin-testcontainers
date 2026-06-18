package tc_docker

// The one-call API: request(client, method, path, body) -> Response.
// Each call opens a fresh connection (Connection: close). Keep-alive can come
// later; correctness first.

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

DEFAULT_SOCKET :: "/var/run/docker.sock"

Client :: struct {
	socket_path: string,
}

// Resolve the daemon socket. An explicit arg always wins; otherwise we resolve
// it the way the docker CLI does (DOCKER_HOST > active context > default).
make_client :: proc(socket_path := "") -> Client {
	if socket_path != "" {
		return Client{socket_path = strings.clone(socket_path)}
	}
	resolved := resolve_socket(context.temp_allocator)
	path := resolved if resolved != "" else DEFAULT_SOCKET
	return Client{socket_path = strings.clone(path)}
}

// Mirror docker CLI socket resolution:
//   1. DOCKER_HOST env (strip unix://)
//   2. context name from DOCKER_CONTEXT env, else ~/.docker/config.json currentContext
//   3. that context's Endpoints.docker.Host in ~/.docker/contexts/meta/<sha256(name)>/meta.json
//   4. "" => caller falls back to DEFAULT_SOCKET
// Returns "" (not the default) on any miss, so make_client owns the fallback.
@(private)
resolve_socket :: proc(allocator := context.temp_allocator) -> string {
	if host := os.get_env("DOCKER_HOST", allocator); host != "" {
		return strip_unix(host)
	}

	name := os.get_env("DOCKER_CONTEXT", allocator)
	if name == "" {
		name = current_context_name(allocator)
	}
	if name == "" || name == "default" {
		return ""
	}
	return context_socket(name, allocator)
}

@(private)
current_context_name :: proc(allocator := context.temp_allocator) -> string {
	home := os.get_env("HOME", allocator)
	if home == "" {
		return ""
	}
	cfg_path := fmt.tprintf("%s/.docker/config.json", home)
	data, rerr := os.read_entire_file(cfg_path, allocator)
	if rerr != nil {
		return ""
	}
	Config :: struct {
		currentContext: string `json:"currentContext"`,
	}
	cfg: Config
	if json.unmarshal(data, &cfg, allocator = allocator) != nil {
		return ""
	}
	return cfg.currentContext
}

@(private)
context_socket :: proc(name: string, allocator := context.temp_allocator) -> string {
	home := os.get_env("HOME", allocator)
	if home == "" {
		return ""
	}
	meta_path := fmt.tprintf(
		"%s/.docker/contexts/meta/%s/meta.json",
		home,
		sha256_hex(name, allocator),
	)
	data, rerr := os.read_entire_file(meta_path, allocator)
	if rerr != nil {
		return ""
	}
	// Endpoints.docker.Host, e.g. "unix:///Users/me/.rd/docker.sock"
	Endpoint :: struct {
		Host: string `json:"Host"`,
	}
	Endpoints :: struct {
		docker: Endpoint `json:"docker"`,
	}
	Meta :: struct {
		Endpoints: Endpoints `json:"Endpoints"`,
	}
	meta: Meta
	if json.unmarshal(data, &meta, allocator = allocator) != nil {
		return ""
	}
	return strip_unix(meta.Endpoints.docker.Host)
}

@(private)
sha256_hex :: proc(s: string, allocator := context.temp_allocator) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]u8)s)
	digest: [32]u8
	sha2.final(&ctx, digest[:])
	hb, _ := hex.encode(digest[:], allocator)
	return string(hb)
}

@(private)
strip_unix :: proc(host: string) -> string {
	if strings.has_prefix(host, "unix://") {
		return host[len("unix://"):]
	}
	return host // bare path or tcp:// (tcp not yet supported by the transport)
}

// Perform one request/response round-trip. Caller owns the Response
// (response_destroy). Returns ok=false on any transport/parse failure.
request :: proc(
	client: Client,
	method, path: string,
	body: []u8 = nil,
	content_type := "",
	allocator := context.allocator,
) -> (
	resp: Response,
	ok: bool,
) {
	conn := dial(client.socket_path) or_return
	defer conn_close(conn)

	req := build_request(method, path, body, content_type, allocator)
	defer delete(req, allocator)
	send_all(conn, req) or_return

	raw := read_all(conn, allocator) or_return
	defer delete(raw)

	return parse_response(raw[:], allocator)
}
