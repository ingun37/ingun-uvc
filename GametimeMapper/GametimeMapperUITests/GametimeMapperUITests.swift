//
//  GametimeMapperUITests.swift
//  GametimeMapperUITests
//
//  Created by Ingun Jon on 11/7/26.
//

import CoreGraphics
import Testing
@testable import GametimeMapperUI

struct GametimeMapperUITests {

    @Test func convertsRotatedDisplaySelectionToVisionCoordinates() {
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let region = VideoRegionGeometry.visionRegion(
            displaySelection: CGRect(x: 0, y: 0, width: 0.25, height: 1),
            naturalSize: CGSize(width: 1920, height: 1080), preferredTransform: rotation)
        #expect(abs(region.minX) < 0.000001)
        #expect(abs(region.minY) < 0.000001)
        #expect(abs(region.width - 1) < 0.000001)
        #expect(abs(region.height - 0.25) < 0.000001)
    }

}
