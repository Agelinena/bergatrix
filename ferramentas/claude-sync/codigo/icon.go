package main

// Ícone da bandeja, desenhado em código: um quadrado arredondado com duas
// setas em círculo (sincronizar) e um ponto de estado no canto.
//   ok     verde     sincronizado
//   busy   amarelo   sincronizando
//   error  vermelho  sem conexão
//   idle   cinza     falta configurar

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/png"
	"math"
	"runtime"
)

var (
	iconBase  = color.RGBA{0xc2, 0x60, 0x3e, 0xff}
	iconWhite = color.RGBA{0xff, 0xff, 0xff, 0xff}
	dotColors = map[string]color.RGBA{
		"ok":    {0x3f, 0xb9, 0x6f, 0xff},
		"busy":  {0xf2, 0xc1, 0x3a, 0xff},
		"error": {0xe5, 0x48, 0x3a, 0xff},
		"idle":  {0x9a, 0x9a, 0x9a, 0xff},
	}
)

func drawIcon(size int, tone string) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, size, size))
	s := float64(size)
	radius := s * 0.22
	// Cobertura com 4x4 amostras por pixel: bordas suaves.
	cover := func(inside func(x, y float64) bool, x, y int) float64 {
		n := 0
		for i := 0; i < 4; i++ {
			for j := 0; j < 4; j++ {
				if inside(float64(x)+(float64(i)+0.5)/4, float64(y)+(float64(j)+0.5)/4) {
					n++
				}
			}
		}
		return float64(n) / 16
	}
	square := func(x, y float64) bool {
		dx := math.Max(math.Max(radius-x, x-(s-radius)), 0)
		dy := math.Max(math.Max(radius-y, y-(s-radius)), 0)
		return dx*dx+dy*dy <= radius*radius
	}
	cx, cy := s/2, s/2
	inner, outer := s*0.20, s*0.31
	ring := func(x, y float64) bool {
		d := math.Hypot(x-cx, y-cy)
		if d < inner || d > outer {
			return false
		}
		a := math.Atan2(y-cy, x-cx) * 180 / math.Pi
		// Duas aberturas, onde ficam as pontas das setas.
		return !(a > -30 && a < 15) && !(a > 150 || a < -165)
	}
	arrow := func(ax, ay, dir float64) func(x, y float64) bool {
		// Triângulo na ponta de cada arco, apontando no sentido do giro.
		w := (outer - inner) * 1.6
		return func(x, y float64) bool {
			px, py := x-ax, (y-ay)*dir
			return py >= 0 && py <= w && math.Abs(px) <= (w-py)*0.9
		}
	}
	arrowA := arrow(cx+(inner+outer)/2, cy-s*0.02, 1)
	arrowB := arrow(cx-(inner+outer)/2, cy+s*0.02, -1)
	dot := dotColors[tone]
	if dot.A == 0 {
		dot = dotColors["idle"]
	}
	dr := s * 0.2
	dcx, dcy := s-dr-s*0.02, s-dr-s*0.02
	dotIn := func(x, y float64) bool { return math.Hypot(x-dcx, y-dcy) <= dr }
	dotBorder := func(x, y float64) bool { return math.Hypot(x-dcx, y-dcy) <= dr+s*0.06 }

	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			var c color.RGBA
			blend := func(top color.RGBA, alpha float64) {
				if alpha <= 0 {
					return
				}
				mix := func(a, b uint8) uint8 { return uint8(float64(a)*(1-alpha) + float64(b)*alpha) }
				c = color.RGBA{mix(c.R, top.R), mix(c.G, top.G), mix(c.B, top.B), uint8(math.Max(float64(c.A), alpha*255))}
			}
			blend(iconBase, cover(square, x, y))
			blend(iconWhite, math.Max(cover(ring, x, y), math.Max(cover(arrowA, x, y), cover(arrowB, x, y))))
			blend(iconWhite, cover(dotBorder, x, y))
			blend(dot, cover(dotIn, x, y))
			img.SetRGBA(x, y, c)
		}
	}
	return img
}

func pngBytes(img image.Image) []byte {
	var buf bytes.Buffer
	_ = png.Encode(&buf, img)
	return buf.Bytes()
}

// icoBytes embrulha PNGs num .ico (o Windows aceita PNG dentro do ICO desde o Vista).
func icoBytes(sizes ...int) func(tone string) []byte {
	return func(tone string) []byte {
		var images [][]byte
		for _, size := range sizes {
			images = append(images, pngBytes(drawIcon(size, tone)))
		}
		var buf bytes.Buffer
		binary.Write(&buf, binary.LittleEndian, [3]uint16{0, 1, uint16(len(images))})
		offset := 6 + 16*len(images)
		for i, data := range images {
			dim := byte(sizes[i])
			if sizes[i] >= 256 {
				dim = 0
			}
			buf.Write([]byte{dim, dim, 0, 0})
			binary.Write(&buf, binary.LittleEndian, [2]uint16{1, 32})
			binary.Write(&buf, binary.LittleEndian, [2]uint32{uint32(len(data)), uint32(offset)})
			offset += len(data)
		}
		for _, data := range images {
			buf.Write(data)
		}
		return buf.Bytes()
	}
}

var windowsIcon = icoBytes(16, 32, 48)

// trayIcon devolve o ícone no formato que a bandeja do sistema espera.
func trayIcon(tone string) []byte {
	if runtime.GOOS == "windows" {
		return windowsIcon(tone)
	}
	return pngBytes(drawIcon(64, tone))
}
