import { Socket, type Channel } from 'phoenix';
import { useEffect } from 'react';

import { SOCKET_URL } from './config';
import { useSession } from './session';

export type ContentStatus = { content_id: string; status: 'ready' | 'failed' };

/**
 * Joins the signed-in user's private channel (`user:<id>`) and calls
 * `onContentStatus` when one of their uploads finishes processing.
 */
export function useContentStatus(onContentStatus: (status: ContentStatus) => void) {
  const { token, me } = useSession();
  const userId = me?.id;

  useEffect(() => {
    if (!token || !userId) return;

    const socket = new Socket(SOCKET_URL, { params: { token } });
    socket.connect();
    const channel: Channel = socket.channel(`user:${userId}`);
    channel.on('content_status', onContentStatus);
    channel.join();

    return () => {
      channel.leave();
      socket.disconnect();
    };
  }, [token, userId, onContentStatus]);
}
