import { FormEvent, useEffect, useMemo, useState } from 'react';
import { supabase } from './supabase';

const MAX_COMMENT_LENGTH = 80;

type SessionState = 'checking' | 'signed-out' | 'otp-sent' | 'signed-in';

function roomCodeFromPath(): string {
  const match = window.location.pathname.match(/\/r\/([A-Za-z0-9_-]+)/);
  return match?.[1]?.toUpperCase() ?? '';
}

function isAllowedMusabiEmail(email: string): boolean {
  const parts = email.trim().toLowerCase().split('@');
  if (parts.length !== 2 || !parts[0] || !parts[1]) return false;
  const domain = parts[1];
  return domain === 'musabi.ac.jp' || domain.endsWith('.musabi.ac.jp');
}

function normalizeComment(text: string): string {
  return text.replace(/\s+/g, ' ').trim();
}

function roomURL(roomCode: string): string {
  return `${window.location.origin}/r/${encodeURIComponent(roomCode)}`;
}

export function App() {
  const roomCode = useMemo(roomCodeFromPath, []);
  const [sessionState, setSessionState] = useState<SessionState>('checking');
  const [email, setEmail] = useState('');
  const [otp, setOtp] = useState('');
  const [comment, setComment] = useState('');
  const [message, setMessage] = useState('');
  const [isBusy, setIsBusy] = useState(false);

  useEffect(() => {
    let isMounted = true;

    supabase.auth.getSession().then(({ data }) => {
      if (!isMounted) return;
      setSessionState(data.session ? 'signed-in' : 'signed-out');
    });

    const { data: listener } = supabase.auth.onAuthStateChange((_event, session) => {
      setSessionState(session ? 'signed-in' : 'signed-out');
    });

    return () => {
      isMounted = false;
      listener.subscription.unsubscribe();
    };
  }, []);

  async function sendOtp(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setMessage('');

    const normalizedEmail = email.trim().toLowerCase();
    if (!isAllowedMusabiEmail(normalizedEmail)) {
      setMessage('musabi.ac.jp またはそのサブドメインのメールアドレスを使ってください。');
      return;
    }

    setIsBusy(true);
    const { error } = await supabase.auth.signInWithOtp({
      email: normalizedEmail,
      options: {
        emailRedirectTo: roomURL(roomCode),
        shouldCreateUser: true,
      },
    });
    setIsBusy(false);

    if (error) {
      setMessage(error.message);
      return;
    }

    setSessionState('otp-sent');
    setMessage('メールに届いた6桁コードを入力してください。');
  }

  async function verifyOtp(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setMessage('');
    setIsBusy(true);

    const { error } = await supabase.auth.verifyOtp({
      email: email.trim().toLowerCase(),
      token: otp.trim(),
      type: 'email',
    });
    setIsBusy(false);

    if (error) {
      setMessage(error.message);
      return;
    }

    setSessionState('signed-in');
    setMessage('');
  }

  async function submitComment(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setMessage('');

    const normalized = normalizeComment(comment);
    if (!normalized) {
      setMessage('コメントを入力してください。');
      return;
    }
    if (normalized.length > MAX_COMMENT_LENGTH) {
      setMessage(`${MAX_COMMENT_LENGTH}文字以内で入力してください。`);
      return;
    }

    setIsBusy(true);
    const { error } = await supabase.rpc('submit_room_comment', {
      p_room_code: roomCode,
      p_content: normalized,
    });
    setIsBusy(false);

    if (error) {
      setMessage(error.message);
      return;
    }

    setComment('');
    setMessage('送信しました。');
  }

  if (!roomCode) {
    return (
      <main className="shell">
        <section className="panel">
          <h1>Room not found</h1>
          <p>投稿URLを確認してください。</p>
        </section>
      </main>
    );
  }

  return (
    <main className="shell">
      <section className="panel">
        <p className="eyebrow">Screen Commentator</p>
        <h1>コメント投稿</h1>
        <p className="room">Room {roomCode}</p>

        {sessionState === 'checking' && <p className="muted">確認中...</p>}

        {sessionState === 'signed-out' && (
          <form onSubmit={sendOtp} className="form">
            <label>
              メールアドレス
              <input
                type="email"
                value={email}
                onChange={(event) => setEmail(event.target.value)}
                placeholder="name@ct.musabi.ac.jp"
                autoComplete="email"
                required
              />
            </label>
            <button type="submit" disabled={isBusy}>
              {isBusy ? '送信中...' : 'コードを送信'}
            </button>
          </form>
        )}

        {sessionState === 'otp-sent' && (
          <form onSubmit={verifyOtp} className="form">
            <label>
              6桁コード
              <input
                type="text"
                value={otp}
                onChange={(event) => setOtp(event.target.value)}
                inputMode="numeric"
                autoComplete="one-time-code"
                maxLength={6}
                required
              />
            </label>
            <button type="submit" disabled={isBusy}>
              {isBusy ? '確認中...' : 'ログイン'}
            </button>
            <button type="button" className="secondary" onClick={() => setSessionState('signed-out')}>
              メールを変更
            </button>
          </form>
        )}

        {sessionState === 'signed-in' && (
          <form onSubmit={submitComment} className="form">
            <label>
              コメント
              <textarea
                value={comment}
                onChange={(event) => setComment(event.target.value)}
                maxLength={MAX_COMMENT_LENGTH}
                rows={3}
                required
              />
            </label>
            <div className="counter">{normalizeComment(comment).length}/{MAX_COMMENT_LENGTH}</div>
            <button type="submit" disabled={isBusy}>
              {isBusy ? '送信中...' : '送信'}
            </button>
            <button type="button" className="secondary" onClick={() => supabase.auth.signOut()}>
              ログアウト
            </button>
          </form>
        )}

        {message && <p className="message">{message}</p>}
      </section>
    </main>
  );
}
