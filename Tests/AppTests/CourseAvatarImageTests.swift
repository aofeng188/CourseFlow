import XCTest
import UIKit
import CourseKit
@testable import CourseFlow

final class CourseAvatarImageTests: XCTestCase {
    func testPhotoBecomesASmallCenteredSquare() throws {
        // 横向大图：左红、中绿、右蓝，裁剪后应只剩中间的绿色。
        let size = CGSize(width: 3000, height: 1000)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let photo = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for (index, color) in [UIColor.red, .green, .blue].enumerated() {
                color.setFill(); context.fill(CGRect(x: CGFloat(index) * 1000, y: 0, width: 1000, height: 1000))
            }
        }
        let data = try XCTUnwrap(CourseAvatarImage.make(from: try XCTUnwrap(photo.pngData())))
        XCTAssertLessThanOrEqual(data.count, CourseAvatarStyle.maxImageBytes)
        let avatar = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(avatar.width, Int(CourseAvatarImage.side)); XCTAssertEqual(avatar.height, Int(CourseAvatarImage.side))
        let pixel = try XCTUnwrap(avatar.cropping(to: CGRect(x: 8, y: 96, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(rgba[1], 200); XCTAssertLessThan(rgba[0], 60); XCTAssertLessThan(rgba[2], 60)
    }

    func testRejectsDataThatIsNotAnImage() {
        XCTAssertNil(CourseAvatarImage.make(from: Data("不是图片".utf8)))
    }
}
