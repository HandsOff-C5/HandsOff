import { useEffect, useRef, type ReactNode } from "react";

// One model's input monitor: a webcam preview with that model's overlay drawn on
// top (hand landmarks, gaze ray, …). Several monitors share ONE injected stream
// (the two-canvas-one-feed layout) so hand-cam and eye-cam show the same input
// interpreted differently. Presentational; the overlay is passed as children.
type ChannelMonitorProps = {
  stream?: MediaStream | null;
  mirrored?: boolean;
  label?: string;
  children?: ReactNode;
};

export function ChannelMonitor({ stream, mirrored, label, children }: ChannelMonitorProps) {
  const videoRef = useRef<HTMLVideoElement>(null);

  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;
    video.srcObject = stream ?? null;
    if (stream) {
      try {
        const playing = video.play();
        if (playing) void playing.catch(() => {});
      } catch {
        // play() is not implemented under jsdom and autoplay can be blocked — ignore.
      }
    }
  }, [stream]);

  return (
    <figure className="channel-monitor" data-testid="channel-monitor" data-active={Boolean(stream)}>
      {label && <figcaption className="channel-monitor__label">{label}</figcaption>}
      <div className="channel-monitor__frame">
        <video
          ref={videoRef}
          data-testid="channel-monitor-video"
          className={`channel-monitor__video${mirrored ? " channel-monitor__video--mirrored" : ""}`}
          muted
          playsInline
        />
        <div className="channel-monitor__overlay">{children}</div>
        {!stream && <p className="channel-monitor__idle">Camera off</p>}
      </div>
    </figure>
  );
}
