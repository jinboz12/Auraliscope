import Foundation

/// Speaker roles carried by every `ChannelFrame`, in its field order. Indices 0–7 are the original 5.1.2
/// roles, so routing saved by earlier versions keeps its meaning; 8–15 extend the layouts up to 9.1.6.
package enum Role {
    package static let count = 16
    package static let left = 0, right = 1, center = 2, lfe = 3, leftSurround = 4, rightSurround = 5
    package static let leftTopFront = 6, rightTopFront = 7, leftRearSurround = 8, rightRearSurround = 9
    package static let leftWide = 10, rightWide = 11, leftTopMiddle = 12, rightTopMiddle = 13
    package static let leftTopRear = 14, rightTopRear = 15

    /// BS.1770-5 channel weights: 1.41 for ear-level channels between 60° and 120° azimuth (side
    /// surrounds and wides), 0 for LFE, 1 elsewhere (front, rear surrounds and the whole upper layer).
    package static let loudnessWeights: [Double] = [1, 1, 1, 0, 1.41, 1.41, 1, 1, 1, 1, 1.41, 1.41, 1, 1, 1, 1]

    /// Positional channels that count as spatial evidence: everything except L, R and LFE.
    package static let evidence = [2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
}
