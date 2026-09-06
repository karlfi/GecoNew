using ClosedXML.Excel;

// Un elenco in Excel: le righe come le da' Dapper (dizionari), le colonne
// scelte dall'endpoint (titolo, campo). Date e numeri restano tali, cosi'
// il file si filtra e si somma in Excel senza rilavorarlo.
static class Esporta
{
    public static IResult Xlsx(IEnumerable<dynamic> righe, string foglio, string nomeFile, (string titolo, string campo)[] colonne)
    {
        using var wb = new XLWorkbook();
        var ws = wb.Worksheets.Add(foglio);
        for (var c = 0; c < colonne.Length; c++) ws.Cell(1, c + 1).Value = colonne[c].titolo;
        var r = 1;
        foreach (IDictionary<string, object?> riga in righe)
        {
            r++;
            for (var c = 0; c < colonne.Length; c++)
            {
                var cella = ws.Cell(r, c + 1);
                var v = riga.TryGetValue(colonne[c].campo, out var x) ? x : null;
                switch (v)
                {
                    case null: break;
                    case DateTime d:
                        cella.Value = d;
                        cella.Style.DateFormat.Format = d.TimeOfDay == TimeSpan.Zero ? "dd/MM/yyyy" : "dd/MM/yyyy HH:mm";
                        break;
                    case bool b: cella.Value = b ? "sì" : "no"; break;
                    case int or long or short or byte: cella.Value = Convert.ToInt64(v); break;
                    case decimal or double or float: cella.Value = Convert.ToDouble(v); break;
                    default: cella.Value = v.ToString(); break;
                }
            }
        }
        var tabella = ws.Range(1, 1, Math.Max(r, 2), colonne.Length);
        tabella.SetAutoFilter();
        ws.Row(1).Style.Font.Bold = true;
        ws.SheetView.FreezeRows(1);
        ws.Columns().AdjustToContents(1, Math.Min(r, 200));
        foreach (var col in ws.Columns()) if (col.Width > 60) col.Width = 60;
        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return Results.File(ms.ToArray(), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", $"{nomeFile}_{DateTime.Now:yyyyMMdd_HHmm}.xlsx");
    }
}
