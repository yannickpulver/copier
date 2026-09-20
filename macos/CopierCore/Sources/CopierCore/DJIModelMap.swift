import Foundation

/// DJI camera model codes to product names.
/// Source: https://commons.wikimedia.org/wiki/DJI_camera_model_names
public enum DJIModels {
    public static let map: [String: String] = [
        // Phantom
        "FC200": "DJI Phantom 2 Vision",
        "FC300C": "DJI Phantom 3 Standard",
        "FC300S": "DJI Phantom 3 Advanced",
        "FC300X": "DJI Phantom 3 Professional",
        "FC300XW": "DJI Phantom 3 4K",
        "FC300SE": "DJI Phantom 3 SE",
        "FC330": "DJI Phantom 4",
        "FC6310": "DJI Phantom 4 Pro",
        "FC6310S": "DJI Phantom 4 Pro V2",
        "FC6310R": "DJI Phantom 4 RTK",
        "FC6360": "DJI P4 Multispectral",
        // Inspire
        "FC350": "DJI Inspire 1",
        "FC550": "DJI Inspire 1 Pro",
        "FC550RAW": "DJI Inspire 1 Pro",
        "FC6510": "DJI Inspire 2",
        "FC6520": "DJI Inspire 2",
        "FC6540": "DJI Inspire 2",
        "FC4280": "DJI Inspire 3",
        // Spark
        "FC1102": "DJI Spark",
        // Mavic
        "FC220": "DJI Mavic Pro",
        "L1D-20c": "DJI Mavic 2 Pro",
        "FC2220": "DJI Mavic 2 Zoom",
        "FC2204": "DJI Mavic 2 Enterprise",
        "FC2403": "DJI Mavic 2 Enterprise Dual",
        "L2D-20c": "DJI Mavic 3",
        "FC4170": "DJI Mavic 3",
        "FC4382": "DJI Mavic 3 Pro",
        "FC4370": "DJI Mavic 3 Pro",
        "M3E": "DJI Mavic 3E",
        "M3M": "DJI Mavic 3M",
        "L3D-100c": "DJI Mavic 4 Pro",
        "FC9284": "DJI Mavic 4 Pro",
        "FC9287": "DJI Mavic 4 Pro",
        // Air
        "FC230": "DJI Mavic Air",
        "FC2103": "DJI Mavic Air 2",
        "FC3170": "DJI Mavic Air 2",
        "FC3411": "DJI Air 2S",
        "FC8282": "DJI Air 3",
        "FC8284": "DJI Air 3",
        "FC9113": "DJI Air 3S",
        "FC9184": "DJI Air 3S",
        // Mini
        "FC7203": "DJI Mini",
        "FC7303": "DJI Mini 2",
        "FC7503": "DJI Mini 2 SE",
        "FC7703": "DJI Mini 4K",
        "FC3682": "DJI Mini 3",
        "FC3582": "DJI Mini 3 Pro",
        "FC8482": "DJI Mini 4 Pro",
        "FC9313": "DJI Mini 5 Pro",
        // Avata / FPV / Flip
        "FC8183": "DJI Avata",
        "FC8485": "DJI Avata 2",
        "OQ001E": "DJI Avata 360",
        "FC8582": "DJI Flip",
        "FC3305": "DJI FPV",
        // Neo
        "FC8671": "DJI Neo",
        "FC9470": "DJI Neo 2",
        // Tello
        "RZ001": "Ryze Tello",
        // Osmo Action / Pocket
        "AC002": "DJI Osmo Action 3",
        "AC003": "DJI Osmo Action 4",
        "AC004": "DJI Osmo Action 5 Pro",
        "PP-101": "DJI Osmo Pocket 3",
        "OW001": "DJI Osmo Nano",
    ]
}
