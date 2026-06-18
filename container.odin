package testcontainers

// Typed container-lifecycle verbs on top of request(): pull, create, start,
// inspect, remove, plus mapped_port to recover the host-side port.

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"

// High-level, user-facing request describing a container to run.
Container_Request :: struct {
	image:           string,        // e.g. "redis:alpine"
	exposed_ports:   []string,      // e.g. {"6379/tcp"} or {"6379"} (defaults to /tcp)
	env:             []string,      // "KEY=VALUE"
	cmd:             []string,
	name:            string,        // optional; Docker auto-names if empty
	wait:            Wait_Strategy, // nil = don't wait for readiness
	startup_timeout: time.Duration, // 0 = DEFAULT_STARTUP_TIMEOUT
	// Optional container HEALTHCHECK. Docker Test form, e.g.
	// {"CMD-SHELL", "redis-cli ping | grep PONG"}. Enables Wait_Healthcheck.
	healthcheck:     []string,
}

// A handle to a created container.
Container :: struct {
	client: Client,
	id:     string,
}

// --- Wire structs (Docker API JSON shapes) -------------------------------

@(private)
Wire_Port_Binding :: struct {
	HostIp:   string `json:"HostIp,omitempty"`,
	HostPort: string `json:"HostPort"`,
}

@(private)
Wire_Host_Config :: struct {
	PortBindings: map[string][]Wire_Port_Binding `json:"PortBindings,omitempty"`,
	Binds:        []string                       `json:"Binds,omitempty"`,
	Privileged:   bool                           `json:"Privileged,omitempty"`,
	AutoRemove:   bool                           `json:"AutoRemove,omitempty"`,
}

@(private)
Wire_Healthcheck :: struct {
	Test:     []string `json:"Test"`,               // e.g. {"CMD-SHELL", "..."}
	Interval: i64      `json:"Interval,omitempty"`,  // nanoseconds
	Timeout:  i64      `json:"Timeout,omitempty"`,   // nanoseconds
	Retries:  int      `json:"Retries,omitempty"`,
}

@(private)
Wire_Create :: struct {
	Image:        string                          `json:"Image"`,
	Cmd:          []string                        `json:"Cmd,omitempty"`,
	Env:          []string                        `json:"Env,omitempty"`,
	Labels:       map[string]string               `json:"Labels,omitempty"`,
	ExposedPorts: map[string]struct {}            `json:"ExposedPorts,omitempty"`,
	Healthcheck:  Maybe(Wire_Healthcheck)         `json:"Healthcheck,omitempty"`,
	HostConfig:   Wire_Host_Config                `json:"HostConfig"`,
}

// Subset of `GET /containers/{id}/json` we care about.
Port_Map_Entry :: struct {
	HostIp:   string `json:"HostIp"`,
	HostPort: string `json:"HostPort"`,
}

Container_Health :: struct {
	Status: string `json:"Status"`, // "starting" | "healthy" | "unhealthy" ("" if no healthcheck)
}

Container_State :: struct {
	Status:   string           `json:"Status"`,
	Running:  bool             `json:"Running"`,
	ExitCode: int              `json:"ExitCode"`,
	Health:   Container_Health `json:"Health"`,
}

Network_Settings :: struct {
	Ports: map[string][]Port_Map_Entry `json:"Ports"`,
}

Inspect :: struct {
	Id:              string           `json:"Id"`,
	State:           Container_State  `json:"State"`,
	NetworkSettings: Network_Settings `json:"NetworkSettings"`,
}

// --- Verbs ---------------------------------------------------------------

// Pull an image. Streams progress JSON which we drain to EOF; success is a 200.
pull_image :: proc(client: Client, image: string, allocator := context.allocator) -> (ok: bool) {
	name, tag := split_image_tag(image)
	path := fmt.tprintf("/images/create?fromImage=%s&tag=%s", name, tag)
	resp := request(client, "POST", path, allocator = allocator) or_return
	defer response_destroy(&resp, allocator)
	return resp.status == 200
}

// Convenience entrypoint: ensure the reaper, create, start, and wait for
// readiness. This is the "Testcontainers" verb. Returns ok=false if the
// container started but never became ready (caller still gets the handle for
// inspection / removal).
run :: proc(client: Client, req: Container_Request, allocator := context.allocator) -> (c: Container, ok: bool) {
	ensure_reaper(client) // best-effort crash-safety; failure is non-fatal

	// Auto-pull so callers don't have to pre-stage the image (Docker is a
	// fast no-op when it's already local).
	if !pull_image(client, req.image) {
		return {}, false
	}
	c = create_container(client, req, allocator) or_return
	if !start_container(c) {
		return c, false
	}
	if req.wait != nil {
		timeout := req.startup_timeout
		if timeout <= 0 {
			timeout = DEFAULT_STARTUP_TIMEOUT
		}
		if !wait_until_ready(c, req.wait, timeout) {
			return c, false
		}
	}
	return c, true
}

create_container :: proc(
	client: Client,
	req: Container_Request,
	allocator := context.allocator,
) -> (
	c: Container,
	ok: bool,
) {
	wire: Wire_Create
	wire.Image = req.image
	wire.Cmd = req.cmd
	wire.Env = req.env

	// Label every managed container so the reaper can find it.
	wire.Labels = make(map[string]string, context.temp_allocator)
	wire.Labels[MANAGED_LABEL] = "true"
	wire.Labels[SESSION_LABEL] = session_id()

	if len(req.healthcheck) > 0 {
		// Fast defaults so test readiness doesn't wait Docker's 30s interval.
		wire.Healthcheck = Wire_Healthcheck {
			Test     = req.healthcheck,
			Interval = i64(1 * time.Second),
			Timeout  = i64(3 * time.Second),
			Retries  = 3,
		}
	}

	wire.ExposedPorts = make(map[string]struct {}, context.temp_allocator)
	wire.HostConfig.PortBindings = make(map[string][]Wire_Port_Binding, context.temp_allocator)
	for p in req.exposed_ports {
		key := normalize_port(p, context.temp_allocator)
		wire.ExposedPorts[key] = {}
		// Empty HostPort => Docker auto-assigns an ephemeral host port.
		bindings := make([]Wire_Port_Binding, 1, context.temp_allocator)
		bindings[0] = Wire_Port_Binding{HostPort = ""}
		wire.HostConfig.PortBindings[key] = bindings
	}

	return create_from_wire(client, wire, req.name, allocator)
}

// Marshal a wire config, POST /containers/create, return a handle. Shared by
// create_container and the reaper (which needs raw Binds/Privileged).
@(private)
create_from_wire :: proc(
	client: Client,
	wire: Wire_Create,
	name := "",
	allocator := context.allocator,
) -> (
	c: Container,
	ok: bool,
) {
	body, merr := json.marshal(wire, allocator = context.temp_allocator)
	if merr != nil {
		return {}, false
	}

	path := "/containers/create"
	if name != "" {
		path = fmt.tprintf("/containers/create?name=%s", name)
	}
	resp := request(client, "POST", path, body, "application/json", allocator) or_return
	defer response_destroy(&resp, allocator)
	if resp.status != 201 {
		return {}, false
	}

	Created :: struct {
		Id: string `json:"Id"`,
	}
	created: Created
	if json.unmarshal(resp.body, &created, allocator = context.temp_allocator) != nil {
		return {}, false
	}
	return Container{client = client, id = strings.clone(created.Id, allocator)}, true
}

start_container :: proc(c: Container, allocator := context.allocator) -> (ok: bool) {
	path := fmt.tprintf("/containers/%s/start", c.id)
	resp := request(c.client, "POST", path, allocator = allocator) or_return
	defer response_destroy(&resp, allocator)
	return resp.status == 204 || resp.status == 304 // 304 = already started
}

inspect_container :: proc(c: Container, allocator := context.allocator) -> (insp: Inspect, ok: bool) {
	path := fmt.tprintf("/containers/%s/json", c.id)
	resp := request(c.client, "GET", path, allocator = allocator) or_return
	defer response_destroy(&resp, allocator)
	if resp.status != 200 {
		return {}, false
	}
	if json.unmarshal(resp.body, &insp, allocator = allocator) != nil {
		return {}, false
	}
	return insp, true
}

// Force-remove the container and its anonymous volumes.
remove_container :: proc(c: Container, allocator := context.allocator) -> (ok: bool) {
	path := fmt.tprintf("/containers/%s?force=true&v=true", c.id)
	resp := request(c.client, "DELETE", path, allocator = allocator) or_return
	defer response_destroy(&resp, allocator)
	return resp.status == 204
}

// Resolve the ephemeral host port bound to a container port (e.g. "6379/tcp").
mapped_port :: proc(c: Container, container_port: string) -> (host_port: int, ok: bool) {
	insp := inspect_container(c, context.temp_allocator) or_return
	key := normalize_port(container_port, context.temp_allocator)
	bindings, has := insp.NetworkSettings.Ports[key]
	if !has {
		return 0, false
	}
	for b in bindings {
		if b.HostPort != "" {
			return strconv.parse_int(b.HostPort)
		}
	}
	return 0, false
}

// --- Helpers -------------------------------------------------------------

@(private)
split_image_tag :: proc(image: string) -> (name: string, tag: string) {
	slash := strings.last_index_byte(image, '/')
	colon := strings.last_index_byte(image, ':')
	if colon > slash {
		return image[:colon], image[colon + 1:]
	}
	return image, "latest"
}

@(private)
normalize_port :: proc(p: string, allocator := context.allocator) -> string {
	if strings.contains(p, "/") {
		return strings.clone(p, allocator)
	}
	return strings.concatenate({p, "/tcp"}, allocator)
}
