## Service ports

Assign custom ports in the machine configuration. Keep standard protocol ports
below `1024`, such as SSH, HTTP, and HTTPS.

Use these conventions for other ports:

| Purpose | Range |
|---|---|
| Application module and role defaults | `1025–9999` |
| Custom port ranges, such as RTP | `10000–32767` |
| Single custom ports | `61000–64999` |
| Listeners bound to a specific address | `65000–65535` |

Prefer custom ports when running multiple instances of a service. Keep application
defaults in `1025–9999` so a single instance can use its default without taking a
port from the custom ranges.

Linux normally uses `32768–60999` for automatic TCP and UDP port allocation.
The custom ranges above avoid that default. If you change the kernel's
[`ip_local_port_range`](https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html#ip-variables),
adjust the allocations accordingly.

For internal services, assign a separate ULA IPv6 address to each instance and
bind to that address on port `65535`. Generate a stable address with
`top.idr-lib.mkLocalIPv6` and add it through
[`idr.preset.loopback.addresses`](../nix/preset/README.md#additional-local-addresses).
A reverse proxy can then forward traffic to the listener. Avoid binding ports
in `65000–65535` to `0.0.0.0` or `::`.
