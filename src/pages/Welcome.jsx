import { Link } from 'react-router-dom';
import { startPrimersSignIn } from '../lib/primersId';

export default function Welcome() {
  return (
    <main className="welcome">
      <div className="welcome-inner">
        <img src="/securelink-logo.png" alt="" width="72" height="72" />
        <h1>Help, one tap away.</h1>
        <p className="lede">
          SecureLink sends your emergency, with your live location, to the nearest police, fire, ambulance
          and road-safety responders. If nobody responds within two minutes it widens the search and asks again.
        </p>
        <div className="stack">
          <button type="button" className="btn primary big" onClick={() => startPrimersSignIn()}>Continue with Primers ID</button>
          <button type="button" className="btn ghost" onClick={() => startPrimersSignIn({ create: true })}>Create a Primers ID</button>
        </div>
        <a className="call112" href="tel:112">In danger right now? Call 112</a>
        <ul className="points">
          <li><b>Pick what is happening.</b> Police, fire, accident or medical alerts go to the responders who handle them.</li>
          <li><b>Your phone dies? The alert stays open.</b> Responders see the last known location and that the signal was lost.</li>
          <li><b>Private by design.</b> Only responders handling your alert see where you are. People nearby only hear that something happened in their area.</li>
        </ul>
        <p className="fine">Signing in shares your name and verified email from Primers ID with SecureLink. <Link to="/privacy">Privacy</Link></p>
      </div>
    </main>
  );
}
