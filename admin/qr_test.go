package main

import (
	"image"
	"image/color"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/makiuchi-d/gozxing"
	"github.com/makiuchi-d/gozxing/qrcode"
)

var (
	svgViewBox = regexp.MustCompile(`viewBox="0 0 (\d+) (\d+)"`)
	svgPath    = regexp.MustCompile(` d="([^"]*)"`)
	svgRun     = regexp.MustCompile(`^M(\d+) (\d+)h(\d+)v1h-(\d+)z`)
)

// decodeQR: what a camera reads in the SVG of qrSVG. Its path drawn again from the
// SVG text (not from the encoder), 4 pixels a module, then read by gozxing, a port of
// ZXing, the decoder of many phones' cameras
func decodeQR(t *testing.T, svg string) string {
	t.Helper()
	box, d := svgViewBox.FindStringSubmatch(svg), svgPath.FindStringSubmatch(svg)
	if box == nil || d == nil || box[1] != box[2] {
		t.Fatalf("not a square QR code: %s", svg)
	}
	side, _ := strconv.Atoi(box[1])
	const scale = 4
	img := image.NewGray(image.Rect(0, 0, side*scale, side*scale))
	for i := range img.Pix {
		img.Pix[i] = 0xff
	}
	path := d[1]
	for path != "" {
		m := svgRun.FindStringSubmatch(path)
		if m == nil || m[3] != m[4] {
			t.Fatalf("not a run of modules: %.40s", path)
		}
		x, _ := strconv.Atoi(m[1])
		y, _ := strconv.Atoi(m[2])
		n, _ := strconv.Atoi(m[3])
		for px := x * scale; px < (x+n)*scale; px++ {
			for py := y * scale; py < (y+1)*scale; py++ {
				img.SetGray(px, py, color.Gray{})
			}
		}
		path = path[len(m[0]):]
	}
	bmp, err := gozxing.NewBinaryBitmapFromImage(img)
	if err != nil {
		t.Fatal(err)
	}
	res, err := qrcode.NewQRCodeReader().Decode(bmp, map[gozxing.DecodeHintType]interface{}{gozxing.DecodeHintType_PURE_BARCODE: true})
	if err != nil {
		t.Fatalf("not readable: %v", err)
	}
	return res.GetText()
}

func TestQRCodeDecodes(t *testing.T) {
	for _, u := range []string{
		"https://accounts.example.com",
		"https://sync.example.com/1.0/sync/1.5",
		"https://a-rather-long-sync-host-name.subdomain.example.com:8443/some/path/1.0/sync/1.5",
	} {
		svg := string(qrSVG(u, "QR code of "+u))
		if got := decodeQR(t, svg); got != u {
			t.Errorf("decoded %q, want %q", got, u)
		}
		if !strings.HasPrefix(svg, `<svg class="qr" xmlns="http://www.w3.org/2000/svg"`) || !strings.Contains(svg, `role="img" aria-label="QR code of `+u+`"`) ||
			strings.Contains(svg, "style") || strings.Contains(svg, "<script") {
			t.Errorf("svg: %s", svg)
		}
	}
	// the label is escaped; too long for a QR code: nothing
	if svg := string(qrSVG("x", `a "b" <c>`)); !strings.Contains(svg, `aria-label="a &#34;b&#34; &lt;c&gt;"`) {
		t.Errorf("label: %s", svg)
	}
	if svg := qrSVG(strings.Repeat("x", 5000), "x"); svg != "" {
		t.Errorf("too long: %.80s", svg)
	}
}
