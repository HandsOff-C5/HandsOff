import { useCallback, useEffect, useRef, useState } from "react";

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

const defaultGetStream: GetStream = (deviceId) =>
  navigator.mediaDevices.getUserMedia({
    video: deviceId ? { deviceId: { exact: deviceId } } : true,
  });

export function useSharedWebcam(getStream: GetStream = defaultGetStream): SharedWebcam {
  const [stream, setStream] = useState<MediaStream | null>(null);
  const [status, setStatus] = useState<WebcamStatus>("idle");
  const [error, setError] = useState<string | undefined>(undefined);
  const mounted = useRef(true);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  const stop = useCallback(() => {
    setStream((current) => {
      current?.getTracks().forEach((track) => track.stop());
      return null;
    });
    setStatus("idle");
    setError(undefined);
  }, []);

  const start = useCallback(() => {
    setStatus("starting");
    setError(undefined);
    void getStream()
      .then((next) => {
        if (!mounted.current) {
          next.getTracks().forEach((track) => track.stop());
          return;
        }
        setStream(next);
        setStatus("live");
      })
      .catch((caught: unknown) => {
        if (!mounted.current) return;
        setError(caught instanceof Error ? caught.message : String(caught));
        setStatus("error");
      });
  }, [getStream]);

  return { stream, status, error, start, stop };
}
