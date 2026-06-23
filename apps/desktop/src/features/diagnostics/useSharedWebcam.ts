// One webcam stream shared by every ChannelMonitor (hand-cam + eye-cam show the
// same feed, different overlays). Acquired on explicit start() — never auto, for
// privacy. getStream is injected so tests don't touch the real camera.
export type WebcamStatus = "idle" | "starting" | "live" | "error";

export type GetStream = (deviceId?: string) => Promise<MediaStream>;

export type SharedWebcam = {
  stream: MediaStream | null;
  status: WebcamStatus;
  error?: string;
  start: () => void;
  stop: () => void;
};

export function useSharedWebcam(_getStream?: GetStream): SharedWebcam {
  void _getStream;
  throw new Error("not implemented");
}
