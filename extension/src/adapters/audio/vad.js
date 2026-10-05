/**
 * Detekcja aktywności głosowej (VAD) na energii ramki.
 *
 * Podłogę szumu wyznaczamy metodą statystyki minimum: sygnał tniemy na
 * podokna i pamiętamy minimum z każdego z nich, a podłoga to minimum z całego
 * bufora. To odporne na dwa przeciwne przypadki, na których wykłada się
 * naiwna średnia ruchoma:
 *
 *  - stały hałas (wentylator, muzyka) — średnia uznaje go za mowę na zawsze,
 *    minimum poprawnie ustawia się na jego poziomie;
 *  - długa nieprzerwana wypowiedź — minimum trzyma się przerw międzysylabowych,
 *    więc podłoga nie wspina się do poziomu mowy i nie ucina jej w połowie.
 *
 * VAD nie decyduje o treści — decyduje tylko, które ramki wpuścić do
 * rozpoznawania mówcy. Fałszywy pozytyw psuje embedding bardziej niż
 * fałszywy negatyw, więc próg jest raczej konserwatywny.
 */

export const VAD_DEFAULTS = {
  /** O ile dB ponad podłogą szumu ramka liczy się jako mowa. */
  thresholdDb: 12,
  /** Ile kolejnych głośnych ramek otwiera wypowiedź (10 ms na ramkę). */
  onsetFrames: 3,
  /** Ile cichych ramek ją zamyka — krótkie pauzy w zdaniu nie mają jej ciąć. */
  hangoverFrames: 25,
  /** Długość podokna statystyki minimum (500 ms). */
  subwindowFrames: 50,
  /** Ile podokien pamiętamy (6 x 500 ms = 3 s historii). */
  subwindows: 6,
  /** Podłoga startowa, zanim zobaczymy jakikolwiek sygnał. */
  initialFloorDb: -70,
};

export class Vad {
  #loudRun = 0;
  #quietRun = 0;
  #subMin = Infinity;
  #subCount = 0;
  #ring;
  #ringIndex = 0;

  constructor(options = {}) {
    const config = { ...VAD_DEFAULTS, ...options };
    this.thresholdDb = config.thresholdDb;
    this.onsetFrames = config.onsetFrames;
    this.hangoverFrames = config.hangoverFrames;
    this.subwindowFrames = config.subwindowFrames;
    this.initialFloorDb = config.initialFloorDb;

    // Bufor wypełniony podłogą startową: zanim uzbieramy historię, VAD ma
    // działać, a nie uznawać wszystkiego za ciszę.
    this.#ring = new Float64Array(config.subwindows).fill(config.initialFloorDb);
    this.noiseFloorDb = config.initialFloorDb;
    this.speaking = false;
  }

  /**
   * @param {number} energyDb energia ramki w dB
   * @returns {{speaking: boolean, started: boolean, ended: boolean, loud: boolean}}
   */
  push(energyDb) {
    this.#trackNoiseFloor(energyDb);
    const loud = energyDb > this.noiseFloorDb + this.thresholdDb;

    let started = false;
    let ended = false;

    if (loud) {
      this.#loudRun++;
      this.#quietRun = 0;
      if (!this.speaking && this.#loudRun >= this.onsetFrames) {
        this.speaking = true;
        started = true;
      }
    } else {
      this.#quietRun++;
      this.#loudRun = 0;
      if (this.speaking && this.#quietRun >= this.hangoverFrames) {
        this.speaking = false;
        ended = true;
      }
    }

    return { speaking: this.speaking, started, ended, loud };
  }

  #trackNoiseFloor(energyDb) {
    if (energyDb < this.#subMin) this.#subMin = energyDb;
    if (++this.#subCount >= this.subwindowFrames) {
      this.#ring[this.#ringIndex] = this.#subMin;
      this.#ringIndex = (this.#ringIndex + 1) % this.#ring.length;
      this.#subMin = Infinity;
      this.#subCount = 0;
    }

    let floor = Infinity;
    for (const value of this.#ring) if (value < floor) floor = value;
    if (this.#subMin < floor) floor = this.#subMin;
    this.noiseFloorDb = floor;
  }

  reset() {
    this.speaking = false;
    this.#loudRun = 0;
    this.#quietRun = 0;
    this.#subMin = Infinity;
    this.#subCount = 0;
    this.#ring.fill(this.initialFloorDb);
    this.noiseFloorDb = this.initialFloorDb;
  }
}
