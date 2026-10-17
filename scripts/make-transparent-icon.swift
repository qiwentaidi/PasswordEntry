import Foundation
import CoreGraphics
import ImageIO

guard CommandLine.arguments.count == 3 else {
    fputs("usage: make-transparent-icon.swift input.png output.png\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("unable to read source image\n", stderr)
    exit(1)
}

let sourceWidth = image.width
let sourceHeight = image.height
let colorSpace = CGColorSpaceCreateDeviceRGB()
var pixels = [UInt8](repeating: 0, count: sourceWidth * sourceHeight * 4)
guard let context = CGContext(data: &pixels, width: sourceWidth, height: sourceHeight, bitsPerComponent: 8, bytesPerRow: sourceWidth * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fputs("unable to create bitmap context\n", stderr)
    exit(1)
}
context.draw(image, in: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))

var minX = sourceWidth
var minY = sourceHeight
var maxX = 0
var maxY = 0
for y in 0..<sourceHeight {
    for x in 0..<sourceWidth {
        let offset = (y * sourceWidth + x) * 4
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        let originalAlpha = Int(pixels[offset + 3])
        let minimum = min(red, green, blue)
        let colorScore = minimum < 80 ? max(0, blue - red - 10) * 6 : 0
        let foregroundAlpha = min(255, colorScore)
        let alpha = originalAlpha < 32 ? 0 : min(originalAlpha, foregroundAlpha)
        pixels[offset] = UInt8(red * alpha / 255)
        pixels[offset + 1] = UInt8(green * alpha / 255)
        pixels[offset + 2] = UInt8(blue * alpha / 255)
        pixels[offset + 3] = UInt8(alpha)
        if alpha > 8 && foregroundAlpha > 20 {
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
}

guard minX <= maxX, minY <= maxY else {
    fputs("source image has no foreground\n", stderr)
    exit(1)
}
context.flush()

let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
let outputSize = 1024
var output = [UInt8](repeating: 0, count: outputSize * outputSize * 4)
guard let outputContext = CGContext(data: &output, width: outputSize, height: outputSize, bitsPerComponent: 8, bytesPerRow: outputSize * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let masked = context.makeImage() else {
    fputs("unable to create output image\n", stderr)
    exit(1)
}
guard let cropped = masked.cropping(to: crop) else {
    fputs("unable to crop foreground\n", stderr)
    exit(1)
}

let target = CGFloat(outputSize) * 0.86
let scale = min(target / crop.width, target / crop.height)
let drawSize = CGSize(width: crop.width * scale, height: crop.height * scale)
let drawRect = CGRect(x: (CGFloat(outputSize) - drawSize.width) / 2, y: (CGFloat(outputSize) - drawSize.height) / 2, width: drawSize.width, height: drawSize.height)
outputContext.interpolationQuality = .high
outputContext.draw(cropped, in: drawRect)
for offset in stride(from: 0, to: output.count, by: 4) {
    if output[offset + 3] < 24 {
        output[offset] = 0; output[offset + 1] = 0; output[offset + 2] = 0; output[offset + 3] = 0
    }
}

guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil),
      let finalImage = outputContext.makeImage() else {
    fputs("unable to write output image\n", stderr)
    exit(1)
}
CGImageDestinationAddImage(destination, finalImage, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("unable to finalize output image\n", stderr)
    exit(1)
}
