# Rapport d'Audit de Sécurité — EventlyMarketsV3 (v3.2)

**Projet :** Evently Markets  
**Contrat :** `EventlyMarketsV3.sol` (1366 lignes, SHA `ee11527`)  
**Date :** 2026-05-05  
**Repo source :** `isonips/evently` @ `398904fe`  
**Auditeur :** Claude Sonnet 4.6 — 8 agents spécialisés en parallèle  
**Branche audit :** `claude/audit-evently-security-Sc9J7`

---

## Post-Audit : Tri des Findings & Correctifs Appliqués

**Date des correctifs :** 2026-05-05  
**Branche correctifs :** `claude/audit-evently-security-Sc9J7`  
**Contrat corrigé :** `evently-v3/contracts/EventlyMarketsV3.sol`

### Faux Positifs & Findings By-Design (non corrigés)

| ID | Verdict | Justification (cross-référencée avec evently-docs) |
|----|---------|-----------------------------------------------------|
| INV-01 | **By design** | Docs : *"optionSupply not updated on peer transfers — Acknowledged — by design, math correct"*. `claimCancelRefund` utilise `optionSupply` mis à jour uniquement sur burn/mint, pas sur transfer peer. La math est correcte. |
| ECON-01 | **Faux positif** | Docs : *"False positive — LMSR solvency mathematically guaranteed: poolBalance + subsidyDeposited = C(q) ≥ q_winner"*. Les fills CLOB utilisent des shares déjà escrowed (SELL path) ou de l'USDm escrowed (BUY path) — pool non affecté. |
| MATH-07 | **Faux positif** | L'invariant `poolBalance + subsidyDeposited = C(q)` est prouvé par construction (`poolBalance += netUsdm = ΔC(q)` sur chaque AMM buy/sell). Pas besoin de vérification on-chain. |
| ATCK-01/EXEC-01 | **Faux positif** | `placeOrder` est `nonReentrant` (`_locked=2` pendant toute l'exécution). Tout appel ré-entrant à `cancelOrder` (aussi `nonReentrant`) revert immédiatement. L'hypothèse d'attaque est invalide. |
| ATCK-02 | **Faux positif** | `claimCancelRefund` est `nonReentrant` + burns les shares avant le transfer (CEI déjà respecté dans le code original). |
| INV-04 | **Faux positif** | La preuve LMSR garantit que le pool couvre tous les winners AMM. Les shares CLOB sont déjà escrowed avant leur transfert — pas de sur-engagement. |
| INV-10 | **By design** | Un marché slashé invalide la résolution → tout le monde est remboursé pro-rata via `claimCancelRefund`. C'est le comportement attendu. Les "losing shares" ont autant droit au remboursement que les "winning shares" puisque la résolution est niée. |
| AC-04 | **Faux positif** | `burnLosingShares` skip explicitement `winningOption`. Impossible de brûler des winning shares par erreur. Les holders omis gardent des shares sans valeur (ne peuvent pas redeem, ne peuvent pas réclamer refund sur marché Finalized). |
| EXT-08 | **By design** | L'oracle centralisé (créateur) est le business model. Le mécanisme de dispute communautaire (50 USDm, 24h) est le check on-chain. Remplacement par UMA/Chainlink = décision de roadmap. |
| ECON-02/BIZ-02 | **By design** | Le collateral fixe de 50 USDm est une décision de product design. Le dispute mechanism compense partiellement le moral hazard. |
| A-05 | **Acknowledged** | Docs : *"A-05 — _cancelAllOrders unbounded gas — Low risk on MegaETH"*. Le pattern REX4-02 (deferred + reclaimCancelledOrder) est la mitigation acceptée. |

### Correctifs Appliqués (13 findings réels)

| ID | Sévérité | Finding | Correctif |
|----|----------|---------|-----------|
| MATH-02+01+04 | **Critique** | `exp()` overflow → DoS permanent + unsafe int256 cast | Ajout `SafeCast.toInt256()` + guard `require(arg <= EXP_MAX_ARG)` dans `_lmsrCost` et `getPrice` |
| MATH-03 | **Critique** | Underflow `costBefore - _lmsrCost()` dans `quoteSell` | `costAfter` calculé séparément, `usdmOut = costBefore >= costAfter ? ... : 0` |
| AC-02 | **Critique** | `transferAdmin()` 1 étape → perte irréversible possible | Two-step : `transferAdmin()` nomme `pendingAdmin`, `acceptAdmin()` finalise |
| ECON-03 | **Critique** | `withdrawResolverPool` admin peut drainer vers n'importe quelle adresse | Signature réduite à `withdrawResolverPool(uint256)`, `msg.sender` doit être `resolverPoolAddress`, fonds envoyés à `resolverPoolAddress` uniquement |
| EXEC-04 | **Medium** | CEI violation `settleDispute` — state mis à jour après `safeTransfer(disputer)` | Tous les effets d'état (`winningOption`, flags, fees) déplacés avant `usdm.safeTransfer()` |
| EXEC-03 | **Medium** | CEI violation `cancelMarket` — `creatorCollateralReturned` mis à jour après transfer | Flag positionné avant `usdm.safeTransfer(m.creator, col)` |
| EXEC-02 | **Medium** | `closeBetting` sans `nonReentrant` — state racing possible via callback | `nonReentrant` ajouté |
| BIZ-04 | **High** | `slashMarket` sur marché Disputed confisque le collateral du disputer honnête vers treasury | Collateral retourné au disputer (`usdm.safeTransfer(m.disputer, DISPUTE_COLLATERAL)`) — le disputer a identifié le problème |
| BIZ-05 | **Medium** | Subsidy bloqué si 0 trades sur cancel (`claimCancelRefund` revert "No supply") | `cancelMarket` : retourne le subsidy au créateur si `totalSupply == 0` ; `slashMarket` : envoie le subsidy à la treasury |
| BIZ-06 | **Medium** | Aucune durée minimale de betting window — flash market possible | Constante `MIN_BETTING_WINDOW = 1 hours` + `require(_bettingDeadline >= block.timestamp + MIN_BETTING_WINDOW)` dans les 3 fonctions de création |
| BIZ-10 | **Low** | `reclaimCancelledOrder` bloqué en état `Disputed` | `MarketStatus.Disputed` ajouté aux statuts acceptés |
| MATH-06 | **Medium** | Fee split — guard précautionnel manquant | `require(creatorCut + treasuryCut <= totalFee, "Fee invariant")` avant calcul de `resolverCut` |
| EXEC-08 | **Low** | `OrderFilled` émis avec `nextOrderId` comme sentinel (incorrect) | Remplacé par `type(uint256).max` comme sentinel "no resting order for taker" |

---

## Résumé Exécutif

EventlyMarketsV3 est un protocole de marchés de prédiction sur MegaETH combinant un AMM LMSR (b=200 USDm) et un CLOB on-chain, avec des positions ERC-1155 fongibles. Le contrat présente une **architecture économique solide** (solvabilité LMSR mathématiquement garantie) et a intégré plusieurs correctifs issus d'audits préliminaires. Toutefois, l'analyse révèle des **risques critiques persistants** dans les domaines de la centralisation admin, des vecteurs de reentrancy résiduelle, des déficits d'incentive du créateur, et de la gestion des états de marché.

### Comptage des Findings

| Sévérité | Agent 1 (ATCK) | Agent 2 (MATH) | Agent 3 (AC) | Agent 4 (ECON) | Agent 5 (EXEC) | Agent 6 (INV) | Agent 7 (EXT) | Agent 8 (BIZ) | **Total** |
|----------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| Critical | 4 | 3 | 4 | 3 | — | 3 | 1 | — | **18** |
| High | 6 | 4 | 4 | 5 | 2 | 1 | 4 | 4 | **30** |
| Medium | 7 | 4 | 3 | 4 | 4 | 3 | 4 | 4 | **29** |
| Low | 5 | 2 | 1 | 3 | 3 | 3 | 2 | 2 | **21** |
| Info | 3 | — | 1 | 2 | 1 | — | — | 3 | **10** |
| **Total** | 25 | 13 | 13 | 17 | 10 | 10 | 11 | 13 | **112** |

### Findings Bloquants (Critical — Pré-déploiement)

| ID | Titre | Module |
|----|-------|--------|
| AC-01 | Admin EOA omnipotent — SPOF absolu | Contrôle d'accès |
| AC-02 | `transferAdmin()` en 1 étape — perte irréversible possible | Contrôle d'accès |
| AC-03 | `slashMarket` + `withdrawTreasury` = rugpull direct | Contrôle d'accès |
| AC-04 | `burnLosingShares` avec liste arbitraire fournie par l'admin | Contrôle d'accès |
| MATH-01 | Overflow `q[i] * 1e18` dans `_lmsrCost` | Mathématiques |
| MATH-02 | `exp()` overflow LMSR — DoS permanent de marché | Mathématiques |
| MATH-03 | Underflow `costBefore - costAfter` dans `quoteSell` | Mathématiques |
| MATH-07 | Invariant de solvabilité LMSR non vérifié on-chain | Mathématiques |
| ECON-01 | Insolvabilité par sur-rédemption (winning shares > pool) | Économique |
| ECON-02 | Moral hazard créateur — résolution biaisée sans contrainte | Économique |
| ECON-03 | Admin drain du resolver pool via `setResolverPoolAddress` | Économique |
| ATCK-01 | Cross-function reentrancy via ERC-1155 callback dans `placeOrder` | Vecteurs d'attaque |
| ATCK-02 | Reentrancy `claimCancelRefund` — double remboursement | Vecteurs d'attaque |
| ATCK-03 | Sandwich attack sur route AMM de `placeOrder` | Vecteurs d'attaque |
| ATCK-04 | DoS `_cancelAllOrders` par gas exhaustion | Vecteurs d'attaque |
| INV-01 | `optionSupply` désynchronisé via peer transfers ERC-1155 | Invariants |
| INV-04 | Drain de `subsidyDeposited` avant claim complet | Invariants |
| INV-10 | Losing shares accessibles après `slashMarket` (status Slashed) | Invariants |
| EXT-08 | Oracle entièrement centralisé — aucune vérification on-chain | Intégrations |

---

## Scope de l'Audit

### Contrat audité
- `EventlyMarketsV3.sol` (v3.2 post-correctifs préliminaires)

### Hors scope
- `EventlyProfiles.sol`, `Megamble.sol`, `MegambleMarketsV2.sol`, `MegambleProfiles.sol`
- Infrastructure off-chain (keeper bot, frontend, session keys Pimlico)
- USDM token lui-même (audité séparément)

### Mécanismes couverts
- LMSR AMM (b=200 USDm, PRBMath SD59x18)
- CLOB (bids + asks, max 200 par livre)
- ERC-1155 positions fongibles
- Cycle de vie du marché (7 états)
- Mécanisme de dispute (24h window)
- Fees (2.5% fixe)
- Burn des losing shares (keeper pattern)

---

## Agent 1 — Vecteurs d'Attaque Connus

### ATCK-01 — CRITICAL — Cross-function Reentrancy via ERC-1155 Callback dans `placeOrder`

**Description :** Dans `placeOrder(BUY)`, le contrat transfère des shares ERC-1155 à l'acheteur pendant la boucle de matching CLOB. Le hook `onERC1155Received` est déclenché avant que l'état interne soit entièrement mis à jour. Un acheteur-contrat peut ré-entrer dans `cancelOrder` ou d'autres fonctions depuis ce callback.

**Impact :** Double-spend sur escrow BUY, drain possible des USDm escrowed.

**PoC :**
```solidity
function onERC1155Received(...) external returns (bytes4) {
    // État intermédiaire : bid partiellement rempli, encore active=true si fill partiel
    market.cancelOrder(partialBidId); // récupère l'escrow résiduel
    return selector;
}
```

**Recommandation :** Appliquer le pattern "accumulate-then-execute" : séparer tous les effets d'état de toutes les interactions dans les boucles de matching. Accumuler les transferts pendants, les exécuter après la boucle complète.

---

### ATCK-02 — CRITICAL — Reentrancy dans `claimCancelRefund`

**Description :** Si `hasClaimed` n'est pas mis à `true` avant le transfert sortant, un contrat malveillant peut ré-entrer dans `claimCancelRefund` depuis un callback ERC-1155 et réclamer plusieurs fois le même remboursement.

**Impact :** Drain du pool de remboursement.

**Recommandation :** Mettre `hasClaimed[msg.sender] = true` en tout premier lieu dans la fonction. Vérifier que `nonReentrant` couvre bien cette fonction.

---

### ATCK-03 — CRITICAL — Sandwich Attack AMM sur `placeOrder`

**Description :** Le LMSR est déterministe et prévisible en mempool. Un attaquant peut front-run un gros ordre BUY AMM, hausser le prix, laisser la victime acheter plus cher, puis back-run via `sellToAMM`.

**Profit estimé :** 1–3% du montant victime selon la profondeur du marché.

**Recommandation :** Documenter et rendre obligatoire l'utilisation du paramètre `_minFill`. Envisager un mécanisme commit-reveal pour les ordres AMM de grande taille.

---

### ATCK-04 — CRITICAL — DoS `_cancelAllOrders` par Gas Exhaustion

**Description :** Avec 200 ordres par livre × 4 options × 2 côtés = 1600 ordres max, `_cancelAllOrders` peut épuiser le gas en une seule transaction. Le pattern REX4-deferred atténue mais ne résout pas le problème fondamental : les fonds peuvent rester bloqués si le keeper ne réclame pas.

**Recommandation :** Migrer vers un pattern pull-only complet pour `_cancelAllOrders`. Ajouter un fee minimum par ordre pour décourager le spam (coût actuel de griefing ≈ gas seul).

---

### ATCK-05 — HIGH — Front-running de `resolveMarket`

**Description :** La transaction `resolveMarket(marketId, winningOption)` est visible en mempool. Un attaquant peut acheter massivement l'option gagnante avant confirmation.

**Recommandation :** Bloquer `placeOrder` dès `BettingClosed`. Implémenter un two-step resolution avec délai de commit.

---

### ATCK-06 — HIGH — Griefing O(n) sur CLOB via `_insertSorted`

**Description :** Remplir un livre avec 200 ordres aux prix extrêmes rend chaque insertion O(200) + nettoyage O(200), coûts gas prohibitifs.

**Recommandation :** TTL sur les ordres, fee non-remboursable de placement, structure de données plus efficace.

---

### ATCK-07 — HIGH — Manipulation de Timestamps (L2/MegaETH)

**Description :** `block.timestamp` contrôlé par le séquenceur. Sur MegaETH, le séquenceur peut avancer le timestamp pour fermer la fenêtre de dispute prématurément.

**Recommandation :** Ajouter une marge de sécurité sur les fenêtres temporelles critiques. Documenter les hypothèses sur MegaETH.

---

### ATCK-08 — HIGH — Phishing via `setApprovalForAll` ERC-1155

**Description :** Si phishiné pour approuver un contrat malveillant, l'attaquant transfère toutes les shares puis redeem les gains.

**Recommandation :** Documenter les risques d'approbation. Envisager des shares non-transférables ou avec restrictions de transfert vers des adresses whitelistées uniquement.

---

### ATCK-09 — HIGH — DoS par Revert dans `_cancelAllOrders`

**Description :** Un contrat maker dont `onERC1155Received` reverte peut bloquer toute la boucle `_cancelAllOrders` si pas de `try/catch`.

**Recommandation :** Wrapper chaque transfert dans `_cancelAllOrders` avec `try/catch`. Isoler les échecs individuels.

---

### ATCK-10 — HIGH — Race Condition `settleDispute`

**Description :** Transaction `settleDispute` visible en mempool permet front-run pour acheter l'option qui sera déclarée gagnante.

**Recommandation :** Bloquer tout trading dès `Disputed`. Vérifier que la transition `BettingClosed → Resolved → Disputed` coupe bien toutes les routes de trade.

---

### ATCK-11 à ATCK-17 — MEDIUM

- **ATCK-11** : Precision loss LMSR — arbitrage sub-wei cumulatif
- **ATCK-12** : Créateur malhonnête — résolution biaisée via collateral fixe (voir BIZ-02)
- **ATCK-13** : `burnLosingShares` — burn prématuré des shares gagnantes par erreur keeper
- **ATCK-14** : Wash trading CLOB entre comptes contrôlés pour fee farming
- **ATCK-15** : Collateral dispute insuffisant — griefing systématique de dispute
- **ATCK-16** : `_cleanBook` — O(n²) worst case lors d'insertions successives
- **ATCK-17** : Phishing ERC-20 `approve` USDm illimité

### ATCK-18 à ATCK-22 — LOW
Manipulation ordering `slashMarket`/`finalizeMarket`, overflow théorique `optionSupply`, events manquants, `creatorAccruedFees` sans limite, front-running de `cancelOrder`.

### ATCK-23 à ATCK-25 — INFO
Centralisation resolver, absence circuit breaker, validation insuffisante paramètres de création.

---

## Agent 2 — Précision Mathématique & Overflows

### MATH-01 — CRITICAL — Overflow `q[i] * 1e18` dans `_lmsrCost`

**Description :** `exp(wrap(int256(q[i] * 1e18 / b_)))` — multiplication intermédiaire sans guard. Avec les paramètres courants (maxQ=26000e18, b=200e18), pas d'overflow actuel, mais sans validation de `b` minimum, un b < 200e18 peut déclencher un overflow ou un cast int256 erroné.

**Recommandation :**
```solidity
function _safeExpArg(uint256 q_i, uint256 b_) internal pure returns (SD59x18) {
    int256 arg = int256(q_i / b_) * 1e18 + int256((q_i % b_) * 1e18 / b_);
    require(arg <= 133_084258667509499441, "LMSR: exp overflow");
    return wrap(arg);
}
```

---

### MATH-02 — CRITICAL — `exp()` Overflow — DoS Permanent de Marché

**Description :** PRBMath SD59x18 `exp(x)` revert pour `x > 133.08e18`. L'argument est `q[i]/b` en unités réelles. Avec b=200, la limite est q[i] > 26616e18. Le cap actuel (26000e18) laisse seulement 2.3% de marge. Tout paramètre `b < 196e18` rendrait le DoS certain.

**Impact :** Gel permanent de tout marché atteignant la limite — `_lmsrCost`, `getPrice`, `quoteBuy`, `quoteSell` revertent.

**Recommandation :** Cap dur sur `q[i]` avant chaque `exp()`. Documenter la limite et le lien avec `b`.

---

### MATH-03 — CRITICAL — Underflow dans `quoteSell`

**Description :** `usdmOut = costBefore - _lmsrCost(q, m.b)` peut paniquer si une erreur d'arrondi PRBMath (±1 ULP) rend `costAfter > costBefore`.

**Recommandation :**
```solidity
uint256 costAfter = _lmsrCost(q, m.b);
usdmOut = costBefore >= costAfter ? costBefore - costAfter : 0;
```

---

### MATH-04 — HIGH — Cast `int256(uint256)` Non Sécurisé

**Description :** Sans `SafeCast`, un `int256(x)` où `x > type(int256).max` interprète la valeur comme négative, passant un argument négatif à `exp()`.

**Recommandation :** Utiliser `SafeCast.toInt256()` d'OpenZeppelin.

---

### MATH-05 — HIGH — Binary Search Floor dans `quoteBuy`

**Description :** La binary search retourne `lo` (floor). L'utilisateur paie le montant exact mais reçoit jusqu'à `1e15 - 1` shares de moins. Sur 1M trades, accumulation de ~500 USDm dans le pool au détriment des traders.

**Recommandation :** Retourner `(lo + hi) / 2` ou réduire la tolérance à `1e12`.

---

### MATH-06 — HIGH — Conflit d'Arrondi dans `_collectFees`

**Description :** Trois divisions entières indépendantes. Si `creatorCut + treasuryCut > totalFee` par arrondi, `resolverCut` underflow et la transaction panic.

**Recommandation :**
```solidity
require(creatorCut + treasuryCut <= totalFee, "Fee invariant broken");
uint256 resolverCut = totalFee - creatorCut - treasuryCut;
```

---

### MATH-07 — HIGH — Invariant de Solvabilité LMSR Non Vérifié

**Description :** `poolBalance + subsidyDeposited >= optionSupply[winner]` est un invariant mathématique du LMSR **pour les shares mintées via AMM seulement**. Les shares CLOB (peer-to-peer) ne passent pas par la pricing function — leur paiement puise dans `subsidyDeposited` sans garantie formelle. Aucun check on-chain n'existe.

**Recommandation :** Vérifier l'invariant dans `finalizeMarket` et ajouter un mode pro-rata si insuffisant.

---

### MATH-08 à MATH-13 — MEDIUM/LOW

- **MATH-08** : Erreur ±200 wei dans subsidy `b * ln(3)` (négligeable)
- **MATH-09** : Token ID collision si `optionIndex >= MAX_OPTIONS` (guard manquant dans certains chemins)
- **MATH-10** : Dust bloqué dans `claimCancelRefund` par division entière
- **MATH-11** : `getPrice` exposition au même overflow exp que MATH-02
- **MATH-12** : Micro-trades sous la fee minimale (MIN_TRADE = 1e15)
- **MATH-13** : Binary search potentiellement non-convergente si PRBMath produit des coûts identiques pour des quantités adjacentes

---

## Agent 3 — Contrôle d'Accès & Permissions

### AC-01 — CRITICAL — Admin EOA Omnipotent

**Description :** L'intégralité des fonctions sensibles (`addToWhitelist`, `slashMarket`, `burnLosingShares`, `withdrawTreasury`, `settleDispute`, `setResolverPoolAddress`, `transferAdmin`) repose sur une adresse unique sans multisig, timelock ou rôles séparés. La compromission d'une clé privée suffit à drainer le protocole.

**Recommandation :**
1. Remplacer par Gnosis Safe multisig (min 3-of-5)
2. `TimelockController` OpenZeppelin (min 48h sur fonctions destructives)
3. Segmentation `AccessControl` : `OPERATOR_ROLE`, `TREASURY_ROLE`, `GUARDIAN_ROLE`

---

### AC-02 — CRITICAL — `transferAdmin()` en Une Étape

**Description :** `admin = _newAdmin` prend effet immédiatement. Un typo ou une clipboard-hijack entraîne la perte permanente du contrôle admin.

**Recommandation :** Utiliser `Ownable2Step` d'OpenZeppelin (two-step ownership avec `acceptAdmin()`).

---

### AC-03 — CRITICAL — `slashMarket` + `withdrawTreasury` = Rugpull

**Description :** Chaîne en 2 transactions : `slashMarket(X)` → collateral vers `treasuryBalance` → `withdrawTreasury(adminWallet, amount)`. Pas de timelock, pas de délai de réaction pour les utilisateurs.

**Recommandation :** Timelock 72h minimum sur `slashMarket`. Fonds slashés vers contrat séparé non contrôlé unilatéralement.

---

### AC-04 — CRITICAL — `burnLosingShares` avec Liste Arbitraire

**Description :** L'admin fournit lui-même la liste `_holders`. Vecteurs d'abus : omission sélective (certains alliés gardent leurs losing shares), inclusion erronée (shares gagnantes brûlées par erreur), manipulation des ratios de paiement.

**Recommandation :** Modèle pull : les perdants ne peuvent simplement pas réclamer (pas besoin de burn actif). Ou Merkle proof de la liste complète avant exécution.

---

### AC-05 — HIGH — `settleDispute()` : Arbitrage Centralisé Sans Appel

**Description :** L'admin est juge unique et final de toutes les disputes. Conflit d'intérêts structurel si l'admin a des positions sur les marchés qu'il arbitre.

**Recommandation :** Intégrer UMA Optimistic Oracle, Kleros ou Reality.eth. Timelock 48h avant effet.

---

### AC-06 — HIGH — `setResolverPoolAddress()` : Auto-Attribution des Fees

**Description :** L'admin peut se désigner lui-même comme `resolverPoolAddress`, puis appeler `withdrawResolverPool(adminWallet, all)` directement (condition `msg.sender == admin` suffit).

**Recommandation :**
```solidity
function withdrawResolverPool(address _to, uint256 _amount) external {
    require(msg.sender == resolverPoolAddress, "Not authorized"); // admin retiré
    require(_to == resolverPoolAddress, "Must withdraw to resolver");
    ...
}
```

---

### AC-07 — HIGH — `createAdminMarket()` Sans Collateral

**Description :** L'admin crée des marchés sans dépôt de 50 USDm. Sans skin-in-the-game, aucune incitation à résoudre honnêtement. L'admin cumule créateur + arbitre.

**Recommandation :** Exiger un collateral même pour les marchés admin, ou exiger un oracle externe pour leur résolution.

---

### AC-08 — HIGH — Marchés Importés : Oracle 100% Centralisé

**Description :** Seul l'admin peut résoudre les marchés importés. Le `pmConditionId` n'est pas vérifié on-chain contre Polymarket/UMA. L'admin peut ignorer l'oracle réel.

**Recommandation :** Intégrer une interface oracle on-chain. Permettre les disputes sur les marchés importés.

---

### AC-09 à AC-12 — MEDIUM/LOW

- **AC-09** : Absence de timelock sur fonctions destructives
- **AC-10** : `whitelistEnabled = false` ouvre la création de marchés à tous
- **AC-11** : Invite codes potentiellement prévisibles
- **AC-12** : `cancelMarket` permissionless post-deadline — vecteur de griefing

---

## Agent 4 — Sécurité Économique

### ECON-01 — CRITICAL — Insolvabilité du Pool par Sur-Rédemption

**Description :** Les fees (2.5%) sont prélevées avant crédit du pool AMM. Le pool reçoit 97.5% du brut mais chaque winning share est payée 1 USDm (100%). Les shares CLOB n'alimentent pas le pool mais donnent droit au même payout. Sur un volume mixte CLOB+AMM important, `poolBalance + subsidyDeposited < totalWinningShares` est possible.

**Recommandation :** Vérifier la solvabilité à la finalisation. Implémenter un mode pro-rata en cas de déficit.

---

### ECON-02 — CRITICAL — Creator Moral Hazard

**Description :** Le créateur choisit librement le `winningOption`. Avec un collateral fixe de 50 USDm, le ratio gain/risque devient >90:1 sur les marchés à fort volume (cf. BIZ-02).

**Calcul :**
| Volume | Gain potentiel malhonnête | Risque | Ratio |
|--------|--------------------------|--------|-------|
| 10k USDm | 450 USDm | 50 USDm | 9:1 |
| 100k USDm | 4500 USDm | 50 USDm | 90:1 |

**Recommandation :** Collateral dynamique proportionnel au volume. Interdiction de trader dans son propre marché. Oracle pour résolution.

---

### ECON-03 — CRITICAL — Admin Drain du Resolver Pool

**Description :** `withdrawResolverPool(adminWallet, resolverPoolBalance)` est appelable directement par l'admin vers n'importe quelle adresse. Les 0.5% de fees cumulés sur tout le volume sont extractibles à tout moment.

**Recommandation :** Contraindre `_to == resolverPoolAddress` dans `withdrawResolverPool`.

---

### ECON-04 — HIGH — Sandwich Attack sur `placeOrder(BUY)` AMM

**Description :** Front-run → prix monte → victime paie plus cher → back-run via `sellToAMM`. Profit estimé : 1–3% du montant victime si `_minFill = 0`.

---

### ECON-05 — HIGH — CLOB Griefing : Saturation des Livres

**Description :** 200 ordres BUY à prix minimal (coût ≈ 0.2 USDm + gas) saturent le bid book, bloquant tout nouveau placement pour les vrais traders.

**Recommandation :** Fee non-remboursable de placement. Minimum de valeur par ordre (ex: 1 USDm).

---

### ECON-06 — HIGH — Flash Loan + Manipulation LMSR

**Description :** Pas de guard anti-flash-loan. Si `getPrice()` est utilisé comme oracle externe, la manipulation devient très profitable. Coût de manipulation solo (50%→90%) ≈ 460 USDm avec perte nette de 22 USDm en isolation.

**Recommandation :** Avertissement explicite que `getPrice()` ne doit pas servir d'oracle externe. TWAP si nécessaire.

---

### ECON-07 — HIGH — Insider Trading du Créateur Avant `bettingDeadline`

**Description :** Le créateur connaît le résultat avant l'annonce. Il peut acheter l'option gagnante juste avant `bettingDeadline`. Profit = (1 - prix_achat) × shares.

**Recommandation :** Lockup des positions créateur jusqu'après la fenêtre dispute.

---

### ECON-08 — HIGH — Redemption Race FIFO Sans Paiement Pro-Rata

**Description :** En cas d'insolvabilité partielle, les premiers redeemers sont intégralement payés et les derniers reçoivent `revert("Subsidy exhausted")`. Leurs fonds sont bloqués à jamais.

**Recommandation :** Mode de paiement pro-rata si `poolBalance + subsidyDeposited < totalWinningShares`.

---

### ECON-09 à ECON-12 — MEDIUM

- **ECON-09** : Arbitrage circulaire CLOB→AMM (limité par 5% de friction)
- **ECON-10** : Market creation griefing par immobilisation de subsidy
- **ECON-11** : Asymétrie de la dispute (ratio 2:1 défavorable au disputer)
- **ECON-12** : `_restOrder` recalcule `usdmEscrowed` incorrectement (arrondi d'annulation)

### ECON-13 à ECON-15 — LOW

- **ECON-13** : Last-minute trading via manipulation timestamp
- **ECON-14** : Fee siphoning resolver pool (redondant avec ECON-03)
- **ECON-15** : `burnLosingShares` incomplet avec flag prématuré

### ECON-16 à ECON-17 — INFO

- **ECON-16** : Opacité de `_collectFees` (brut vs net non documenté)
- **ECON-17** : `subsidyDeposited` non inclus dans `getPoolBalance()` — monitoring trompeur

---

## Agent 5 — Reentrancy & Ordre d'Exécution

### EXEC-01 — HIGH — Cross-function Reentrancy `placeOrder` SELL → `cancelOrder`

**Description :** Dans la boucle SELL, `_safeTransferFrom(contract, bid.maker, ...)` déclenche `onERC1155Received`. Si le bid maker est un contrat, il peut appeler `cancelOrder` sur son propre ordre partiellement rempli (encore `active = true`), récupérant l'escrow résiduel pendant que la boucle principale continue.

**Séquence d'attaque :**
```
1. AttackContract place BID partiellement rempli
2. Victime vend → SELL path, fill partiel → bid.active = true, bid.quantityRemaining > 0
3. _safeTransferFrom → onERC1155Received → cancelOrder(bid) → escrow retourné
4. Boucle SELL continue : bid.active = false → skip (pas double-fill)
```

**Recommandation :** Pattern accumulate-then-execute : séparer effets et interactions dans les boucles CLOB.

---

### EXEC-02 — HIGH — Cross-function Reentrancy `placeOrder` BUY → `closeBetting`

**Description :** `closeBetting` n'a pas de `nonReentrant`. Depuis un callback `onERC1155Received` pendant `placeOrder(BUY)` (locked=2), l'attaquant peut appeler `closeBetting` si `block.timestamp >= bettingDeadline`, passant le marché à `BettingClosed`. La Phase 2 AMM de `placeOrder` mint alors des shares dans un marché fermé.

**Recommandation :** Ajouter `nonReentrant` à `closeBetting`.

---

### EXEC-03 — MEDIUM — CEI Violation dans `cancelMarket`

**Description :**
```solidity
usdm.safeTransfer(m.creator, col);     // INTERACTION avant flag
m.creatorCollateralReturned = true;    // EFFECT après
```
Violation CEI identique à celle corrigée par SEC-01 dans `finalizeMarket`. Le transfert vers le créateur-contrat peut déclencher un hook avant la mise à jour du flag.

**Recommandation :**
```solidity
m.creatorCollateralReturned = true; // Effect d'abord
usdm.safeTransfer(m.creator, col);  // Puis interaction
```

---

### EXEC-04 — MEDIUM — CEI Violation dans `settleDispute`

**Description :** Dans la branche `!creatorWasRight`, `usdm.safeTransfer(m.disputer, 75e18)` est appelé **avant** que `m.winningOption`, `m.creatorCollateralReturned`, `m.status` soient mis à jour. L'état intermédiaire est incohérent pendant l'appel externe.

**Recommandation :** Tous les effets d'état avant toute interaction externe.

---

### EXEC-05 à EXEC-07 — MEDIUM

- **EXEC-05** : Reentrancy résiduelle dans `_cancelAllOrders` (mitigée par `nonReentrant`)
- **EXEC-06** : `burnLosingShares` — callbacks ERC-1155 `_burn` (mitigé par `nonReentrant` et flag préemptif)
- **EXEC-07** : `closeBetting` sans `nonReentrant` — state racing

### EXEC-08 — LOW — `OrderFilled` Émis avec `nextOrderId` Incorrect

**Description :**
```solidity
emit OrderFilled(nextOrderId, asks[i], fill, cost); // BUY path
```
`nextOrderId` est l'ID du *prochain* ordre à créer, pas celui du taker. Les indexeurs off-chain construiront des analytics incorrectes.

**Recommandation :** Utiliser `type(uint256).max` comme sentinel pour "aucun ordre resting taker".

### EXEC-09 à EXEC-10 — LOW/INFO
- **EXEC-09** : `redeemInviteCode` sans `nonReentrant` (risque théorique futur)
- **EXEC-10** : `upvoteMarket` sans `nonReentrant` (pas d'impact financier)

---

## Agent 6 — Invariants de Protocole

### INV-01 — CRITICAL — `optionSupply` Désynchronisé via Peer Transfers ERC-1155

**Description :** `ERC1155.safeTransferFrom` entre utilisateurs ne met pas à jour `optionSupply`. Si Alice transfère des shares à Bob via un peer transfer, puis que le marché est annulé, `claimCancelRefund` calcule les remboursements sur une base erronée. Les derniers claimants peuvent recevoir plus que leur quote-part réelle, drainant `subsidyDeposited` au-delà de son solde.

**Recommandation :** Snapshot de `optionSupply` au moment de `cancelMarket` → `cancelSupplySnapshot[marketId][i]`. Baser les remboursements sur ce snapshot immuable.

---

### INV-02 — HIGH — Shares CLOB Escrowed Orphelines en Cancel

**Description :** Les SELL orders CLOB transfert les shares au contrat (escrow). Si le marché est annulé et que ces shares ne sont pas retournées aux makers originaux avant `claimCancelRefund`, elles restent dans `optionSupply` gonflant la base de calcul. Les fonds USDm correspondants restent bloqués dans le contrat.

**Recommandation :** Tracker les SELL orders escrowed. À `cancelMarket`, retourner les shares aux makers originaux avant calcul des remboursements.

---

### INV-03 — MEDIUM — `poolBalance` Non Alimenté par CLOB Fills BUY

**Description :** Les CLOB fills BUY transfèrent le USDm directement du buyer au seller. `poolBalance` n'augmente pas. Les shares ainsi acquises donnent droit à 1 USDm en payout qui puise dans `poolBalance`/`subsidyDeposited` sans y avoir contribué.

**Recommandation :** Audit formel que `poolBalance + subsidyDeposited >= optionSupply[winner]` après chaque cycle. Check en fin de `resolveMarket`.

---

### INV-04 — CRITICAL — Drain de `subsidyDeposited` Avant Claim Complet

**Description :** Si `poolBalance = 0` (sells AMM massifs) et que `subsidyDeposited` s'épuise avant que tous les winners aient réclamé (via `redeemWinnings`), les derniers holders reçoivent `revert("Subsidy exhausted")`.

**Recommandation :**
```solidity
require(poolBalance + subsidyDeposited >= optionSupply[marketId][winningOption],
    "Insolvency: insufficient for all winners");
```

---

### INV-05 à INV-08 — MEDIUM/LOW

- **INV-05** : Arrondi fee non absorbé (dust résiduel)
- **INV-06** : `winningOption = 0` ambigu (mitigation nécessaire par sentinel)
- **INV-07** : Guard `createdAt != 0` fragile (préférer `marketId < nextMarketId`)
- **INV-08** : Cap 200 orders potentiellement franchi momentanément (ordre `_cleanBook` → `_restOrder`)

### INV-09 — INFO — Double Finalisation : Non Exploitable

**Description :** Les deux chemins `Resolved → Finalized` et `Disputed → Finalized` sont mutuellement exclusifs par les guards de statut. **Pas de violation.**

### INV-10 — CRITICAL — Losing Shares Accessibles Après `slashMarket`

**Description :** `claimCancelRefund` accepte `Slashed` comme statut valide. Si un marché en état `Resolved` est slasher, les holders de losing shares (non brûlées car `burnLosingShares` n'est jamais appelé en Resolved) peuvent réclamer des remboursements sur des shares sans valeur économique, au détriment des autres participants.

**Recommandation :** Isoler la logique `Slashed` dans une fonction distincte. `claimCancelRefund` limité au seul statut `Cancelled`.

---

## Agent 7 — Intégrations Externes & Oracles

### EXT-01 — HIGH — USDM Fee-on-Transfer

**Description :** Si USDM implémente des fees de transfert, le contrat comptabilise les montants bruts mais reçoit les montants nets. Insolvabilité progressive, derniers réclamants ne peuvent être payés.

**Recommandation :** Balance-delta pattern :
```solidity
uint256 balanceBefore = usdm.balanceOf(address(this));
usdm.safeTransferFrom(msg.sender, address(this), amount);
uint256 received = usdm.balanceOf(address(this)) - balanceBefore;
```

---

### EXT-02 — HIGH — USDM Pausable

**Description :** Si USDM est pausable (pattern USDC), toutes les opérations sont bloquées. Traders piégés, gains inaccessibles, aucun circuit breaker interne.

**Recommandation :** Circuit breaker interne indépendant. Mécanisme d'urgence avec IOUs.

---

### EXT-03 — HIGH — USDM Blacklist

**Description :** Si le contrat ou un utilisateur est blacklisté, les transferts revertent. Fonds définitivement bloqués. Vecteur de griefing légal (pression réglementaire sur l'émetteur USDM).

**Recommandation :** Pull-payment pattern. `claimable[user][marketId]` séparé des transferts immédiats.

---

### EXT-04 — MEDIUM — USDM Upgradeability

**Description :** Si USDM est un proxy upgradeable, un changement de `decimals()` (ex: 18→6) invalide tous les calculs PRBMath. Un comportement modifié peut rendre insolvable le protocole.

**Recommandation :** Vérifier `usdm.decimals() == 18` dans le constructor. Monitoring de l'adresse d'implémentation.

---

### EXT-05 — HIGH — PRBMath `exp()` Overflow à Fort Volume

**Description :** Identique à MATH-02 — `exp()` revert pour `q[i]/b > 133.08`. Sur un marché sans cap de volume, le DoS est certain avec accumulation suffisante.

---

### EXT-06 — MEDIUM — PRBMath `ln()` sur Argument Edge Case

**Description :** Si `n = 0` ou `n = 1` passe la validation, `ln(0)` revert et `ln(1e18) = 0` crée un marché sans subsidy (LMSR dégénéré).

---

### EXT-07 — LOW — `MEGA_LIMIT_CONTROL` Jamais Appelée

**Description :** La constante est déclarée mais `remainingComputeGas()` n'est jamais utilisée. `gasleft()` est utilisé à la place. Incohérence code/documentation. Risque latent si un développeur futur utilise la constante en supposant qu'elle est fonctionnelle.

---

### EXT-08 — CRITICAL — Oracle Entièrement Centralisé

**Description :** La résolution de tous les marchés (réguliers via créateur, importés via admin) est humaine et centralisée. Aucune interface on-chain vers Polymarket/UMA. Le `pmConditionId` est une string non vérifiable. Single point of failure complet.

**Recommandation :** Intégration UMA Optimistic Oracle ou Chainlink pour la vérification automatique des outcomes.

---

### EXT-09 à EXT-11 — LOW/MEDIUM

- **EXT-09** : Collision `keccak256(pmConditionId)` — risque de normalisation string
- **EXT-10** : ERC-4337 whitelist par adresse wallet (friction sur changement de wallet)
- **EXT-11** : Absence de circuit breaker sur compromission USDM

---

## Agent 8 — Logique Métier & Premiers Principes

### Preuve de Solvabilité LMSR (Confirmée)

> **L'invariant `poolBalance + subsidyDeposited = C(q)` est mathématiquement garanti pour toutes les opérations AMM pures.**

- Création : `C([0,...,0]) = b*ln(n) = subsidyDeposited` ✓
- AMM buy : `poolBalance += C(q_new) - C(q_old)` par construction de `quoteBuy` ✓
- AMM sell : `poolBalance -= C(q_old) - C(q_new)` par `quoteSell` ✓
- Corollaire : `C(q) >= q_winner` → `poolBalance + subsidyDeposited >= optionSupply[winner]` ✓

**Note critique :** Cette garantie ne s'applique qu'aux shares mintées via AMM. Les shares CLOB (peer-to-peer) brisent potentiellement l'invariant si leur volume est significatif (voir ECON-01, MATH-07).

---

### BIZ-01 — HIGH — Marchés Admin Sans Collateral Ni Dispute

**Description :** `createAdminMarket` → `creatorCollateralReturned = true` dès la création. L'admin cumule créateur (sans collateral), résolveur et arbitre final des disputes. Aucune pénalité financière possible en cas de résolution malhonnête.

**Scénario :** Admin crée un marché populaire (100k USDm volume), achète secrètement l'option perdante, résout incorrectement, empoche 4500+ USDm. Aucun recours.

**Recommandation :** Exiger collateral admin. Interdire à l'admin de trader dans ses marchés. Oracle externe pour résolution.

---

### BIZ-02 — HIGH — Collateral Fixe Non-Scalable avec le Volume

**Description :** 50 USDm de collateral quelle que soit la taille du marché. Sur 100k USDm de volume : ratio gain/risque = 90:1 pour un créateur malhonnête.

**Recommandation :** `max(50e18, totalVolume * 2%)` avec plafond. Ou interdiction de positions créateur dans son propre marché.

---

### BIZ-03 — HIGH — Marchés Importés Entièrement Centralisés

**Description :** Seul l'admin peut résoudre les marchés importés. Pas de dispute possible. Aucune vérification on-chain de l'outcome Polymarket réel.

**Recommandation :** Interface oracle on-chain. Disputes possibles avec arbitre tiers.

---

### BIZ-04 — HIGH — Slash d'un Marché `Disputed` Confisque le Disputer Honnête

**Description :**
```solidity
if (m.status == MarketStatus.Disputed && m.disputer != address(0)) {
    treasuryBalance += DISPUTE_COLLATERAL; // Disputer perd 50 USDm sans jugement
}
```
Un disputer qui avait raison de contester perd son collateral si l'admin slash plutôt que settle.

**Recommandation :** Sur slash d'un marché Disputed, retourner le collateral au disputer :
```solidity
usdm.safeTransfer(m.disputer, DISPUTE_COLLATERAL); // pas treasury
```

---

### BIZ-05 — MEDIUM — Subsidy Stranded si 0 Trades Avant Cancel

**Description :** Si un marché est annulé sans aucun trade, `claimCancelRefund` revert avec "No supply". Le subsidy (138–277 USDm) est définitivement bloqué — ni récupérable par le créateur, ni par l'admin via `withdrawTreasury`.

**Recommandation :** Dans `cancelMarket`, si `allTotal == 0`, retourner le subsidy directement au créateur.

---

### BIZ-06 — MEDIUM — Aucune Durée Minimale de Betting Window

**Description :** `require(_bettingDeadline > block.timestamp)` sans durée minimale. Un créateur peut définir `bettingDeadline = block.timestamp + 1`, s'assurer d'être le seul à trader, puis résoudre immédiatement.

**Recommandation :** `require(_bettingDeadline >= block.timestamp + MIN_BETTING_WINDOW)` avec `MIN_BETTING_WINDOW = 1 hours`.

---

### BIZ-07 — MEDIUM — Aucune Pénalité pour Non-Résolution Créateur

**Description :** Si le créateur ne résout pas, le marché peut être annulé après `resolutionDeadline` et le créateur récupère son collateral intégral. Il a déjà collecté 1% de fees sur tout le volume sans obligation de résoudre.

**Recommandation :** Retenir une partie du collateral si annulation par timeout. Ou confisquer `creatorAccruedFees` vers treasury.

---

### BIZ-08 — MEDIUM — b=200 Fixe : Barrière Élevée et Sensibilité au Capital

**Description :**
- Coût de création : 188–327 USDm (collateral + subsidy)
- Manipulation 50%→95% : ~460 USDm (accessible aux baleines)
- `b` inadapté à la taille réelle du marché

**Recommandation :** `b` configurable dans `[MIN_B, MAX_B]` par le créateur, avec subsidy calculé dynamiquement.

---

### BIZ-09 — LOW — Asymétrie des Frais AMM vs CLOB

**Description :** Sur les fills CLOB, c'est toujours le vendeur qui paie les fees. Sur l'AMM, c'est l'acheteur. Cette asymétrie désavantage structurellement les makers CLOB ask.

**Recommandation :** Splitter maker/taker (ex: maker 0.5%, taker 2%).

---

### BIZ-10 — LOW — `reclaimCancelledOrder` Bloqué en État `Disputed`

**Description :** `reclaimCancelledOrder` n'accepte pas le statut `Disputed`. Des fonds escrowed DEferred par REX4-02 pendant `resolveMarket` restent bloqués si le marché passe en Disputed.

**Recommandation :** Ajouter `MarketStatus.Disputed` à la liste acceptée dans `reclaimCancelledOrder`.

---

### BIZ-11 à BIZ-13 — INFO

- **BIZ-11** : Resolver pool — retrait vers adresse arbitraire
- **BIZ-12** : `winningOption = 0` par défaut — non exploitable grâce aux guards de statut ✓
- **BIZ-13** : Admin — point de confiance unique pour les disputes

---

## Tableau de Priorité Globale

### Priorité P0 — Bloquants Absolus (avant tout déploiement)

| ID | Finding | Impact |
|----|---------|--------|
| AC-01 | Admin EOA omnipotent | Rugpull complet |
| AC-02 | `transferAdmin` 1 étape | Perte irréversible admin |
| AC-03 | Slash + treasury drain | Rugpull direct |
| AC-04 | `burnLosingShares` liste arbitraire | Destruction tokens utilisateurs |
| EXEC-01 | Reentrancy `placeOrder` SELL | Double-spend |
| EXEC-04 | CEI `settleDispute` | État incohérent pendant transfer |
| ECON-01 | Insolvabilité pool | Fonds bloqués |
| ECON-02 | Moral hazard créateur | Résolution frauduleuse rentable |
| BIZ-04 | Slash punit disputer honnête | Destruction incentive dispute |
| INV-01 | `optionSupply` désync | Sur-remboursement |
| INV-10 | Losing shares accessibles après slash | Double paiement |
| MATH-02 | `exp()` overflow DoS | Gel permanent de marché |
| MATH-03 | Underflow `quoteSell` | Revert inattendu |
| EXT-08 | Oracle centralisé | Single point of failure |

### Priorité P1 — Critiques (avant lancement public)

| ID | Finding |
|----|---------|
| AC-05 | `settleDispute` sans appel |
| AC-06 | Resolver pool auto-attribution |
| ECON-03 | Admin drain resolver pool |
| ECON-08 | Redemption FIFO sans pro-rata |
| EXEC-02 | Reentrancy `closeBetting` via callback |
| EXEC-03 | CEI `cancelMarket` |
| BIZ-01 | Marchés admin sans collateral |
| BIZ-02 | Collateral fixe non-scalable |
| BIZ-03 | Marchés importés centralisés |
| BIZ-05 | Subsidy stranded sans trades |
| INV-02 | Shares CLOB orphelines en cancel |
| INV-04 | Drain subsidyDeposited |
| MATH-01 | Overflow `q[i] * 1e18` |
| MATH-06 | Underflow fee split |
| MATH-07 | Invariant solvabilité non vérifié |

### Priorité P2 — Importants (à corriger dans les 30 jours)

| ID | Finding |
|----|---------|
| ECON-04/05 | MEV sandwich + CLOB griefing |
| EXT-01/02/03 | Risques token USDM (fee-on-transfer, pause, blacklist) |
| ATCK-04/09 | DoS `_cancelAllOrders` |
| BIZ-06/07 | Betting window sans minimum, pas de pénalité inaction |
| EXEC-08 | `OrderFilled` ID incorrect |
| MATH-05 | Binary search floor |
| BIZ-10 | `reclaimCancelledOrder` bloqué en Disputed |
| AC-07/08 | Marchés admin/importés centralisés |

### Priorité P3 — Améliorations (roadmap)

- Décentralisation admin (multisig, timelock, DAO)
- Intégration oracle UMA/Chainlink
- `b` configurable
- Asymétrie fees AMM vs CLOB
- Documentation et vues pour intégrateurs

---

## Recommandations Architecturales

### 1. Décentralisation Admin (P0)
```solidity
// Remplacer immédiatement
admin = msg.sender; // EOA

// Par
import "@openzeppelin/contracts/governance/TimelockController.sol";
// + Gnosis Safe 3-of-5 comme proposer
```

### 2. Two-Step Admin Transfer (P0)
```solidity
import "@openzeppelin/contracts/access/Ownable2Step.sol";
```

### 3. CEI dans les Boucles CLOB (P0)
```solidity
// Pattern accumulate-then-execute
PendingTransfer[] memory pending;
// ... boucle effets seulement ...
for (uint i = 0; i < pending.length; i++) { executeTransfer(pending[i]); }
```

### 4. Guard Anti-exp() Overflow (P0)
```solidity
int256 constant EXP_MAX = 133_084258667509499441; // PRBMath SD59x18 limit
require(int256(q[i] * 1e18 / b_) <= EXP_MAX, "LMSR: exp overflow");
```

### 5. Invariant de Solvabilité (P1)
```solidity
function finalizeMarket(uint256 _marketId) external nonReentrant {
    // ... logique existante ...
    require(
        m.poolBalance + m.subsidyDeposited >= optionSupply[_marketId][m.winningOption],
        "Solvency invariant broken"
    );
}
```

### 6. Balance-Delta pour Dépôts USDM (P1)
```solidity
uint256 before = usdm.balanceOf(address(this));
usdm.safeTransferFrom(msg.sender, address(this), amount);
uint256 received = usdm.balanceOf(address(this)) - before;
require(received == amount, "Fee-on-transfer not supported");
```

---

## Conclusion

EventlyMarketsV3 est un protocole techniquement ambitieux avec une implémentation mathématique LMSR correcte et un design économique prometteur. Les correctifs appliqués en v3.2 (CEI sur `finalizeMarket`, nonReentrant généralisé, `_cleanBook` immédiat) témoignent d'un processus d'audit itératif sérieux.

Cependant, **le contrat ne devrait pas être déployé en production avant la résolution des 14 findings P0**. La centralisation totale de l'admin (AC-01 à AC-04) représente un risque systémique qui dépasse la portée de tout correctif de code individuel — c'est une décision architecturale fondamentale qui requiert l'adoption d'un modèle de gouvernance distribué.

Les risques économiques (ECON-01, ECON-02, BIZ-02) sont inhérents au modèle de marchés de prédiction avec résolution humaine et nécessitent soit une révision des incitations, soit l'intégration d'oracles décentralisés.

---

*Ce rapport a été produit par 8 agents Claude Sonnet 4.6 spécialisés analysant indépendamment le contrat EventlyMarketsV3.sol. Il ne remplace pas un audit professionnel par une firme de sécurité certifiée. Tests de fuzzing (Echidna/Medusa) et vérification formelle (Certora Prover) sont fortement recommandés avant tout déploiement mainnet.*

**SHA du contrat audité :** `ee11527be46042e9f9e2655a79aa534536f0fcd3`  
**Commit audit :** `419b612` (branche `claude/audit-evently-security-Sc9J7`)
