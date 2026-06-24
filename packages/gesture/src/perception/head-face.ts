export interface HeadFacePoint {
  x: number;
  y: number;
  z: number;
  visibility: number;
}

export interface HeadFaceBox {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface HeadFaceLandmarks {
  leftEye: HeadFacePoint[];
  rightEye: HeadFacePoint[];
  nose: HeadFacePoint[];
}

export interface HeadFaceCue {
  id: string;
  confidence: number;
  box: HeadFaceBox;
  center: HeadFacePoint;
  landmarks: HeadFaceLandmarks;
  landmarkAvailability: {
    leftEye: boolean;
    rightEye: boolean;
    nose: boolean;
  };
  eyeMidpoint: HeadFacePoint | null;
  eyeDistance: number | null;
  noseOffset: { x: number; y: number } | null;
  yaw: number | null;
  pitch: number | null;
}

export interface HeadFaceFrame {
  frameId?: number;
  timestampMs: number;
  cues: HeadFaceCue[];
}

export interface RawHeadFacePoint {
  x: number;
  y: number;
  z?: number;
  visibility?: number;
}

export interface RawHeadFaceLandmarks {
  leftEye?: RawHeadFacePoint[];
  rightEye?: RawHeadFacePoint[];
  nose?: RawHeadFacePoint[];
}

export interface RawHeadFaceCandidate {
  id?: string;
  confidence: number;
  boundingBox: HeadFaceBox;
  landmarks?: RawHeadFaceLandmarks;
  yaw?: number | null;
  pitch?: number | null;
}

export interface RawHeadFaceFrame {
  faces: RawHeadFaceCandidate[];
}

export function parseHeadFaceFrame(
  raw: RawHeadFaceFrame,
  timestampMs: number,
  frameId?: number,
): HeadFaceFrame {
  finite("timestampMs", timestampMs);
  return {
    ...(frameId !== undefined ? { frameId } : {}),
    timestampMs,
    cues: raw.faces.map(parseFace),
  };
}

function parseFace(face: RawHeadFaceCandidate, index: number): HeadFaceCue {
  confidence(face.confidence);
  box(face.boundingBox);

  const landmarks = {
    leftEye: points(face.landmarks?.leftEye ?? []),
    rightEye: points(face.landmarks?.rightEye ?? []),
    nose: points(face.landmarks?.nose ?? []),
  };
  const leftEye = centroid(landmarks.leftEye);
  const rightEye = centroid(landmarks.rightEye);
  const nose = centroid(landmarks.nose);
  const eyeMidpoint =
    leftEye && rightEye ? point((leftEye.x + rightEye.x) / 2, (leftEye.y + rightEye.y) / 2) : null;
  const eyeDistance =
    leftEye && rightEye ? Math.hypot(rightEye.x - leftEye.x, rightEye.y - leftEye.y) : null;

  return {
    id: face.id ?? `face-${index}`,
    confidence: face.confidence,
    box: face.boundingBox,
    center: point(
      face.boundingBox.x + face.boundingBox.width / 2,
      face.boundingBox.y + face.boundingBox.height / 2,
    ),
    landmarks,
    landmarkAvailability: {
      leftEye: landmarks.leftEye.length > 0,
      rightEye: landmarks.rightEye.length > 0,
      nose: landmarks.nose.length > 0,
    },
    eyeMidpoint,
    eyeDistance,
    noseOffset:
      eyeMidpoint && nose && eyeDistance && eyeDistance > 0
        ? {
            x: (nose.x - eyeMidpoint.x) / eyeDistance,
            y: (nose.y - eyeMidpoint.y) / eyeDistance,
          }
        : null,
    yaw: nullableFinite("yaw", face.yaw ?? null),
    pitch: nullableFinite("pitch", face.pitch ?? null),
  };
}

function points(raw: RawHeadFacePoint[]): HeadFacePoint[] {
  return raw.map(({ x, y, z = 0, visibility = 1 }) => {
    finite("x", x);
    finite("y", y);
    finite("z", z);
    confidence(visibility, "visibility");
    return { x, y, z, visibility };
  });
}

function centroid(points: HeadFacePoint[]): HeadFacePoint | null {
  if (points.length === 0) return null;
  const sum = points.reduce(
    (acc, value) => ({
      x: acc.x + value.x,
      y: acc.y + value.y,
      z: acc.z + value.z,
      visibility: acc.visibility + value.visibility,
    }),
    point(0, 0),
  );
  return {
    x: sum.x / points.length,
    y: sum.y / points.length,
    z: sum.z / points.length,
    visibility: sum.visibility / points.length,
  };
}

function point(x: number, y: number): HeadFacePoint {
  finite("x", x);
  finite("y", y);
  return { x, y, z: 0, visibility: 1 };
}

function box(value: HeadFaceBox) {
  finite("box.x", value.x);
  finite("box.y", value.y);
  finite("box.width", value.width);
  finite("box.height", value.height);
  if (value.width <= 0 || value.height <= 0) {
    throw new Error("face bounding box width and height must be positive");
  }
}

function confidence(value: number, name = "confidence") {
  finite(name, value);
  if (value < 0 || value > 1) throw new Error(`${name} must be between 0 and 1`);
}

function nullableFinite(name: string, value: number | null): number | null {
  if (value === null) return null;
  finite(name, value);
  return value;
}

function finite(name: string, value: number) {
  if (!Number.isFinite(value)) throw new Error(`${name} must be finite`);
}
