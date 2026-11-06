package main

import (
	"fmt"
	"html"
	"html/template"
	"strings"

	"rsc.io/qr"
)

// QR codes of the connect page: the address a phone needs, for its camera instead of
// typing it. rsc.io/qr (BSD, the Go authors', no dependencies) makes the modules; they
// are drawn here as inline SVG: no script, no image request, nothing the CSP has to allow.

// qrCode: an address and its QR code, for the "qr" template of connect.html
type qrCode struct {
	SVG template.HTML
	URL string
}

const qrQuiet = 4 // the white margin of the spec, in modules

// qrSVG: text as a QR code, an <svg> named by label for screen readers; empty if it does
// not fit in one
func qrSVG(text, label string) template.HTML {
	code, err := qr.Encode(text, qr.M)
	if err != nil {
		return ""
	}
	side := code.Size + 2*qrQuiet
	var path strings.Builder
	// one rectangle per run of dark modules on a row
	for y := 0; y < code.Size; y++ {
		for x := 0; x < code.Size; {
			if !code.Black(x, y) {
				x++
				continue
			}
			run := 1
			for x+run < code.Size && code.Black(x+run, y) {
				run++
			}
			fmt.Fprintf(&path, "M%d %dh%dv1h-%dz", x+qrQuiet, y+qrQuiet, run, run)
			x += run
		}
	}
	// (dark on white whatever the color scheme: cameras read that)
	return template.HTML(fmt.Sprintf(`<svg class="qr" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" role="img" aria-label="%s" shape-rendering="crispEdges">`+
		`<rect width="%d" height="%d" fill="#fff"/><path fill="#000" d="%s"/></svg>`,
		side, side, html.EscapeString(label), side, side, path.String()))
}
