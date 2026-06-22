import { describe, expect, it } from "vitest";

import { createAssemblyAiStream } from "./assemblyai-stream";

class FakeWebSocket extends EventTarget {
  binaryType: BinaryType = "blob";
  readyState: number = WebSocket.CONNECTING;

  constructor(readonly url: string) {
    super();
  }

  open() {
    this.readyState = WebSocket.OPEN;
    this.dispatchEvent(new Event("open"));
  }

  send(data: unknown) {
    void data;
  }

  close() {
    this.readyState = WebSocket.CLOSED;
  }
}

async function flush() {
  await Promise.resolve();
  await Promise.resolve();
}

describe("createAssemblyAiStream", () => {
  it("uses the provided token when opening the AssemblyAI WebSocket", async () => {
    const sockets: FakeWebSocket[] = [];
    const stream = createAssemblyAiStream({
      tokenProvider: async () => "worker-token",
      webSocketFactory: (url) => {
        const socket = new FakeWebSocket(url);
        sockets.push(socket);
        return socket as unknown as WebSocket;
      },
      micFactory: async () => ({ stop: async () => {} }),
    });

    const started = stream.start(() => {});
    await flush();
    const socket = sockets[0];
    if (!socket) throw new Error("expected WebSocket to be created");
    socket.open();
    await started;

    expect(socket.url).toContain("token=worker-token");
    await stream.stop();
  });

  it("maps token acquisition failure to a provider-unavailable start error", async () => {
    const stream = createAssemblyAiStream({
      tokenProvider: async () => {
        throw new Error("worker down");
      },
    });

    await expect(stream.start(() => {})).rejects.toMatchObject({
      sttError: {
        kind: "provider-unavailable",
        message: "Could not obtain a streaming token",
      },
    });
  });
});
