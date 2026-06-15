
CREATE VIEW [dbo].[V_DW_punteggiGiorno]
AS
SELECT TOP (100) PERCENT Data, IDFILIALE, SUM(Punteggio) AS Punteggio, Giorno, Mese, Anno, Settimana, COUNT(*) AS Giornate, CONVERT(int, SUM(Punteggio) / COUNT(*)) AS Media
FROM  dbo.V_UtentiAttivita2024
WHERE (Punteggio > 0) AND (Data >= DATEADD(day, - 15, GETDATE()))
GROUP BY Data, IDFILIALE, Giorno, Mese, Anno, Settimana
ORDER BY Data

