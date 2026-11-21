import Foundation

/// Groups the user can switch on or off in Settings › What to announce.
nonisolated enum ObjectCategory: String, CaseIterable, Sendable {
    case people, vehicles, obstacles, animals, signs

    var title: String {
        switch self {
        case .people: "People"
        case .vehicles: "Vehicles and bikes"
        case .obstacles: "Furniture and obstacles"
        case .animals: "Animals"
        case .signs: "Signs and traffic lights"
        }
    }
}

/// What we assume about each detector class. Labels are COCO names (used by most YOLO models).
/// Unknown labels get a 1 m height, low danger, no ground assumption, and the "signs" group,
/// so small things (cups, phones) rarely alert.
enum ObjectCatalog {
    struct Info {
        let height: Double          // typical real height in meters
        let danger: Double          // class weight in the hazard score, 0–1
        let standsOnGround: Bool    // its box bottom touches the floor (enables ground-based distance)
        let category: ObjectCategory
    }

    static func info(for label: String) -> Info {
        known[canonical(label)] ?? Info(height: 1.0, danger: 0.3, standsOnGround: false, category: .signs)
    }

    static func spokenName(for label: String) -> String {
        let label = canonical(label)
        return renamed[label] ?? label
    }

    /// Models spell COCO classes differently (YOLOv3 Tiny says "motorbike", "diningtable").
    private static func canonical(_ label: String) -> String {
        let label = label.lowercased().replacingOccurrences(of: "_", with: " ")
        return aliases[label] ?? label
    }

    private static let aliases: [String: String] = [
        "motorbike": "motorcycle",
        "sofa": "couch",
        "pottedplant": "potted plant",
        "diningtable": "dining table",
        "tvmonitor": "tv",
        "aeroplane": "airplane",
    ]

    private static func entry(_ height: Double, _ danger: Double, _ category: ObjectCategory, ground: Bool = true) -> Info {
        Info(height: height, danger: danger, standsOnGround: ground, category: category)
    }

    private static let known: [String: Info] = [
        "person": entry(1.7, 0.7, .people),
        "bicycle": entry(1.0, 0.9, .vehicles),
        "motorcycle": entry(1.1, 1.0, .vehicles),
        "car": entry(1.5, 1.0, .vehicles),
        "bus": entry(3.0, 1.0, .vehicles),
        "truck": entry(3.0, 1.0, .vehicles),
        "train": entry(3.5, 1.0, .vehicles),
        "dog": entry(0.5, 0.7, .animals),
        "cat": entry(0.3, 0.5, .animals),
        "horse": entry(1.6, 0.8, .animals),
        "chair": entry(0.9, 0.8, .obstacles),
        "bench": entry(0.8, 0.8, .obstacles),
        "couch": entry(0.9, 0.6, .obstacles),
        "bed": entry(0.6, 0.5, .obstacles),
        "dining table": entry(0.75, 0.7, .obstacles),
        "toilet": entry(0.75, 0.5, .obstacles),
        "potted plant": entry(0.6, 0.6, .obstacles),
        "fire hydrant": entry(0.7, 0.8, .obstacles),
        "parking meter": entry(1.3, 0.8, .obstacles),
        "suitcase": entry(0.6, 0.7, .obstacles),
        "refrigerator": entry(1.8, 0.5, .obstacles),
        "stop sign": entry(0.75, 0.3, .signs, ground: false),
        "traffic light": entry(1.0, 0.3, .signs, ground: false),
    ]

    private static let renamed: [String: String] = [
        "dining table": "table",
        "potted plant": "plant",
        "motorcycle": "motorbike",
        "tv": "TV",
    ]
}
