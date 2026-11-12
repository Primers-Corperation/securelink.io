import { Link } from 'react-router-dom';

export default function Privacy() {
  return (
    <main className="page prose">
      <p><Link to="/">‹ SecureLink</Link></p>
      <h1>Privacy policy</h1>
      <p className="muted">Last updated 12 November 2026. SecureLink is operated by Securelink Defence International Limited, a Primers Group company, Abuja, Nigeria. This policy follows the Nigeria Data Protection Act 2023.</p>

      <h2>What we collect and why</h2>
      <ul>
        <li><b>Your Primers ID details.</b> When you sign in, Primers ID shares your name and verified email (and phone number if you added one). We use them to show responders who needs help and how to reach you.</li>
        <li><b>Location during an alert.</b> When you raise an alert we record where you are, and keep recording it while the alert is open, so responders can find you. We do not track you at any other time.</li>
        <li><b>Audio you choose to send.</b> Recordings are only made when you press record during an alert.</li>
        <li><b>A rough area, if you switch on area alerts.</b> We store a grid square of about 5 km, never your exact position, and delete it when you switch the setting off.</li>
        <li><b>Alert history and an audit log</b> of who opened, took, resolved or viewed each alert.</li>
      </ul>

      <h2>Who sees it</h2>
      <ul>
        <li><b>Responder agencies</b> your alert is sent to (police, fire, ambulance, road safety and similar, chosen by the type of alert and distance) see your name, phone, location, movement and audio for that alert.</li>
        <li><b>People nearby</b> who switched on area alerts only learn that an emergency of a certain type happened within about 5 km. They never see who or exactly where.</li>
        <li><b>SecureLink operators</b> see counts, times and categories. To see a person's location or audio they must open a time-limited, written, audited access grant for one alert, for example to help a responder find someone.</li>
        <li>We do not sell personal data or use it for advertising.</li>
      </ul>

      <h2>How long we keep it</h2>
      <p>Alert records, locations and audio are kept for 12 months after an alert closes, then deleted, unless a responder agency or a court lawfully needs them longer for an investigation. Audit logs are kept for 2 years.</p>

      <h2>Your rights</h2>
      <p>You can ask for a copy of your data, ask us to correct or delete it, or object to how we use it, by emailing <b>primerscorperation@gmail.com</b>. Deleting your Primers ID deletes your SecureLink data, except records we must keep by law. You can also complain to the Nigeria Data Protection Commission.</p>

      <h2>Important</h2>
      <p>SecureLink helps reach responders who have joined the service. It does not replace the national emergency line. If you are in danger, <a href="tel:112">call 112</a>.</p>
      <p>See also the <a href="https://primersgroup.ng/privacy/#primers-id" target="_blank" rel="noopener noreferrer">Primers ID privacy policy</a>.</p>
    </main>
  );
}
