import { Socket, type Channel } from 'phoenix';
import { useEffect } from 'react';

import { SOCKET_URL } from './config';
import { useSession } from './session';

export type ContentStatus = { content_id: string; status: 'ready' | 'failed' };

/**
 * Joins the signed-in user's private channel (`user:<id>`) and calls
 * `onContentStatus` when one of their uploads finishes processing.
 *
 * Events aren't replayed after a disconnect, so `onJoined` runs on every
 * successful join and rejoin: callers use it to re-fetch anything they may
 * have missed while offline.
 */
export function useContentStatus(
  onContentStatus: (status: ContentStatus) => void,
  onJoined?: () => void,
) {
  const { token, me } = useSession();
  const userId = me?.id;

  useEffect(() => {
    if (!token || !userId) return;

    const socket = new Socket(SOCKET_URL, { params: { token } });
    socket.connect();
    const channel: Channel = socket.channel(`user:${userId}`);
    channel.on('content_status', onContentStatus);
    // Receive hooks on the join push fire again on each automatic rejoin.
    channel.join().receive('ok', () => onJoined?.());

    return () => {
      channel.leave();
      socket.disconnect();
    };
  }, [token, userId, onContentStatus, onJoined]);
}
