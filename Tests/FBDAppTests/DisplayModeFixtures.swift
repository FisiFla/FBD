import FBDCore

/// Mode lists shaped like real displays, for the mode-list logic tests.
enum DisplayModeFixtures {
    /// A 13" MacBook Air-like list: two logical sizes at the panel's 1.54 aspect, each as a
    /// HiDPI and a non-HiDPI mode, the native-pixel mode, one 4:3 mode, and the default size
    /// at two lower refresh rates. `[0]` is the default mode (1470×956 HiDPI, 60 Hz).
    static func macBookAir() -> [DisplayMode]? {
        [
            mode(1, 1470, 956, hiDPI: true),
            mode(2, 1470, 956),
            mode(3, 1710, 1112, hiDPI: true),
            mode(4, 1710, 1112),
            mode(5, 2940, 1912),
            mode(6, 1024, 768),
            mode(7, 1470, 956, hiDPI: true, refreshRate: 50),
            mode(8, 1470, 956, hiDPI: true, refreshRate: 48),
        ]
    }

    private static func mode(
        _ number: Int32,
        _ width: Int32,
        _ height: Int32,
        hiDPI: Bool = false,
        refreshRate: Double = 60
    ) -> DisplayMode {
        var flags: Int32 = DisplayMode.safeFlag
        if hiDPI { flags |= DisplayMode.hiDPIFlag }
        return DisplayMode(
            modeNumber: number,
            flags: flags,
            width: width,
            height: height,
            pixelsWide: hiDPI ? width * 2 : width,
            pixelsHigh: hiDPI ? height * 2 : height,
            refreshRate: refreshRate,
            encoding: "RGB "
        )
    }
}
