import AudioRingBufferC
import LowEndDSPCoreC

/// The preview and the callback packet are produced by this same calculation.
struct SpatialGeometrySnapshot {
    let raw: LCSpatialGeometryResult

    static func make(sampleRate: Float, settings: SpatialSettings) -> SpatialGeometrySnapshot? {
        var input = LCSpatialGeometryInput(
            enabled: settings.enabled ? 1 : 0,
            listenerX: settings.listenerX, listenerZ: settings.listenerZ,
            speakerWidth: settings.speakerWidth, amount: settings.amount
        )
        var result = LCSpatialGeometryResult()
        guard lc_spatial_geometry_precompute(
            sampleRate, &input, UInt32(Spatializer.delayCapacity), &result
        ) != 0 else { return nil }
        return SpatialGeometrySnapshot(raw: result)
    }
}
