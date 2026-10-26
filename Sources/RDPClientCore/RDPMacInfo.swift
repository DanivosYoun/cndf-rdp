import FreeRDPBridge

public enum RDPMacInfo {
    public static let packageVersion = "0.5.0"
    public static let freerdpVersion = String(cString: rdp_bridge_freerdp_version())
    public static let buildConfiguration = "SwiftPM; FreeRDP vendored; cliprdr, drdynvc, disp, rdpgfx, rdpdr, drive, rdpsnd, macaudio"
}
