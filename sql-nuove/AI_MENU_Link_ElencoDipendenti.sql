-- =============================================================
-- "Elenco Dipendenti" apre la pagina nuova solo su speedyweb.
--
-- La voce di menu resta Videata = RisultatoInterrogazioni, che e' quello che
-- legge tweb: continua a vedere la griglia di sempre. La webapp nuova invece
-- guarda prima il campo Link, che tweb ignora, e da li' apre la pagina
-- ElencoDipendenti (stessa query, ma con la colonna Stato modificabile).
--
-- Parametri resta invariato: IdQuery e sWhere li legge la pagina nuova come
-- faceva quella generica.
--
-- Idempotente. Per tornare indietro basta rimettere Link = '/interrogazioni'.
-- =============================================================
UPDATE MENU_ELEMENTI
SET Link = '/elenco-dipendenti'
WHERE IdMenuElemento = 1461                       -- Gestione Dipendenti > Elenco Dipendenti
  AND Videata = 'RisultatoInterrogazioni';

-- Le quattro voci "Dipendenti in scadenza a N mesi" girano sulla stessa query
-- 1093, cambia solo il where sulla DataFine che arriva da Parametri: stessa
-- pagina, stessa colonna Stato modificabile.
UPDATE MENU_ELEMENTI
SET Link = '/elenco-dipendenti'
WHERE IdMenuElemento IN (1612, 1613, 1614, 1615)   -- Dipendenti in scadenza a 1/2/3 mesi e oltre
  AND Videata = 'RisultatoInterrogazioni';

SELECT IdMenuElemento, Text, Videata, Link
FROM MENU_ELEMENTI
WHERE IdMenuElemento IN (1461, 1612, 1613, 1614, 1615)
ORDER BY IdMenuElemento;
