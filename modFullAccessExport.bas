Attribute VB_Name = "modFullAccessExport"
Option Compare Database
Option Explicit

' Access database exporter. Built for Access 2007+ on Windows.
' Uses DAO plus Windows UTF-8 conversion; no third-party tools are required.

#If VBA7 Then
Private Declare PtrSafe Function WideCharToMultiByte Lib "kernel32" ( _
    ByVal CodePage As Long, ByVal dwFlags As Long, _
    ByVal lpWideCharStr As LongPtr, ByVal cchWideChar As Long, _
    ByVal lpMultiByteStr As LongPtr, ByVal cbMultiByte As Long, _
    ByVal lpDefaultChar As LongPtr, ByVal lpUsedDefaultChar As LongPtr) As Long
Private Declare PtrSafe Function GetLocaleInfoW Lib "kernel32" ( _
    ByVal Locale As Long, ByVal LCType As Long, _
    ByVal lpLCData As LongPtr, ByVal cchData As Long) As Long
#Else
Private Declare Function WideCharToMultiByte Lib "kernel32" ( _
    ByVal CodePage As Long, ByVal dwFlags As Long, _
    ByVal lpWideCharStr As Long, ByVal cchWideChar As Long, _
    ByVal lpMultiByteStr As Long, ByVal cbMultiByte As Long, _
    ByVal lpDefaultChar As Long, ByVal lpUsedDefaultChar As Long) As Long
Private Declare Function GetLocaleInfoW Lib "kernel32" ( _
    ByVal Locale As Long, ByVal LCType As Long, _
    ByVal lpLCData As Long, ByVal cchData As Long) As Long
#End If

Private Const CP_UTF8 As Long = 65001
Private Const LOCALE_USER_DEFAULT As Long = &H400
Private Const LOCALE_SDECIMAL As Long = &HE
Private Const CHUNK_SIZE As Long = 32768

Private gRoot As String
Private gManifestFN As Integer
Private gAttachmentManifestFN As Integer
Private gBinaryManifestFN As Integer
Private gTableSummaryFN As Integer
Private gErrors As Long
Private gWarnings As Long

'==============================
' ENTRY POINT
'==============================
Public Sub ExportEverything()
    Dim db As DAO.Database
    Dim t As DAO.TableDef
    Dim q As DAO.QueryDef
    Dim o As AccessObject
    Dim tableNo As Long, queryNo As Long, objectNo As Long
    Dim statusText As String, messageText As String

    On Error GoTo FatalError

    If Len(CurrentProject.Path) = 0 Then
        MsgBox "Save the Access database to disk before exporting.", vbExclamation
        Exit Sub
    End If

    gErrors = 0
    gWarnings = 0
    gRoot = CreateExportRoot()
    If Len(gRoot) = 0 Then
        MsgBox "Could not create an export folder. Check folder permissions and free disk space.", vbCritical
        Exit Sub
    End If

    EnsureFolder gRoot & "\Tables"
    EnsureFolder gRoot & "\Attachments"
    EnsureFolder gRoot & "\Binary"
    EnsureFolder gRoot & "\Schema"
    EnsureFolder gRoot & "\Queries"
    EnsureFolder gRoot & "\Forms"
    EnsureFolder gRoot & "\Reports"
    EnsureFolder gRoot & "\Macros"
    EnsureFolder gRoot & "\Modules"

    gManifestFN = OpenUtf8Output(gRoot & "\manifest.csv")
    gAttachmentManifestFN = OpenUtf8Output(gRoot & "\Attachments\attachments_manifest.csv")
    gBinaryManifestFN = OpenUtf8Output(gRoot & "\Binary\binary_manifest.csv")
    gTableSummaryFN = OpenUtf8Output(gRoot & "\Schema\table_export_summary.csv")

    WriteUtf8Line gManifestFN, CsvRow(Array("Timestamp", "ObjectType", "ObjectName", "Status", "Details"))
    WriteUtf8Line gAttachmentManifestFN, CsvRow(Array("Table", "Field", "RecordOrdinal", "PrimaryKeyJSON", "AttachmentOrdinal", "OriginalFileName", "RelativePath", "Status", "Details"))
    WriteUtf8Line gBinaryManifestFN, CsvRow(Array("StorageKind", "Table", "Field", "RecordOrdinal", "PrimaryKeyJSON", "RelativePath", "Bytes", "Status", "Details"))
    WriteUtf8Line gTableSummaryFN, CsvRow(Array("Table", "ExportFile", "LinkedTable", "RowsWritten", "Status", "Details"))

    WriteReadme
    Set db = CurrentDb

    ' Structure is exported independently, so one schema failure does not stop data export.
    ExportSchema db

    ' Export all non-system tables. A table error is logged and the next table is attempted.
    tableNo = 0
    For Each t In db.TableDefs
        If Not IsSystemObject(t.Name) Then
            tableNo = tableNo + 1
            ExportTable db, t, tableNo
        End If
    Next t

    ' Saved queries: SQL text plus Access object text when supported.
    queryNo = 0
    For Each q In db.QueryDefs
        If Not IsSystemObject(q.Name) Then
            queryNo = queryNo + 1
            ExportQuery q, queryNo
        End If
    Next q

    objectNo = 0
    For Each o In CurrentProject.AllForms
        objectNo = objectNo + 1
        ExportAccessObject acForm, o.Name, "Forms", "F", objectNo
    Next o

    objectNo = 0
    For Each o In CurrentProject.AllReports
        objectNo = objectNo + 1
        ExportAccessObject acReport, o.Name, "Reports", "R", objectNo
    Next o

    objectNo = 0
    For Each o In CurrentProject.AllMacros
        objectNo = objectNo + 1
        ExportAccessObject acMacro, o.Name, "Macros", "M", objectNo
    Next o

    objectNo = 0
    For Each o In CurrentProject.AllModules
        objectNo = objectNo + 1
        ExportAccessObject acModule, o.Name, "Modules", "V", objectNo
    Next o

    If gErrors = 0 And gWarnings = 0 Then
        statusText = "OK"
    ElseIf gErrors > 0 Then
        statusText = "PARTIAL"
    Else
        statusText = "WARNINGS"
    End If

    LogEvent "Database", CurrentProject.Name, statusText, _
             "Export pass finished. Errors=" & CStr(gErrors) & "; warnings/partial events=" & CStr(gWarnings)

    CloseExportFiles
    messageText = "Export pass finished." & vbCrLf & vbCrLf & _
                  "Folder: " & gRoot & vbCrLf & _
                  "Errors logged: " & CStr(gErrors) & vbCrLf & _
                  "Warnings/partial events logged: " & CStr(gWarnings) & vbCrLf & vbCrLf & _
                  "Review manifest.csv before treating this export as complete."
    If gErrors = 0 And gWarnings = 0 Then
        MsgBox messageText, vbInformation
    Else
        MsgBox messageText, vbExclamation
    End If
    Exit Sub

FatalError:
    LogEvent "Exporter", "ExportEverything", "ERROR", _
             "Fatal error " & CStr(Err.Number) & ": " & Err.Description
    CloseExportFiles
    MsgBox "The export stopped because of a fatal error." & vbCrLf & _
           "Error: " & CStr(Err.Number) & " - " & Err.Description & vbCrLf & _
           "Partial output, if any, is at: " & gRoot & vbCrLf & _
           "Check manifest.csv if it was created.", vbCritical
End Sub

'==============================
' ROOT / FOLDER / FILE HANDLING
'==============================
Private Function CreateExportRoot() As String
    Dim bases(0 To 2) As String
    Dim i As Long, attempt As Long, baseExists As Boolean
    Dim candidate As String, stamp As String, profile As String

    stamp = Format$(Now, "yyyymmdd_hhnnss")
    profile = Environ$("USERPROFILE")

    ' Prefer the database folder when it is short; then Documents, TEMP, and lastly the database folder.
    If Len(CurrentProject.Path) > 0 And Len(CurrentProject.Path) <= 100 Then bases(0) = CurrentProject.Path
    If Len(profile) > 0 Then bases(1) = profile & "\Documents"
    bases(2) = Environ$("TEMP")
    If Len(bases(0)) = 0 Then
        bases(0) = bases(1)
        bases(1) = bases(2)
        bases(2) = CurrentProject.Path
    End If

    For i = LBound(bases) To UBound(bases)
        If Len(bases(i)) > 0 Then
            On Error Resume Next
            baseExists = (Len(Dir$(bases(i), vbDirectory)) > 0)
            If Err.Number <> 0 Then
                Err.Clear
                baseExists = False
            End If
            On Error GoTo 0

            If baseExists Then
                For attempt = 0 To 99
                    candidate = bases(i) & "\AccessExport_" & stamp
                    If attempt > 0 Then candidate = candidate & "_" & Format$(attempt, "00")
                    On Error Resume Next
                    If Len(Dir$(candidate, vbDirectory)) = 0 Then
                        Err.Clear
                        MkDir candidate
                        If Err.Number = 0 Then
                            If Len(Dir$(candidate, vbDirectory)) > 0 Then
                                CreateExportRoot = candidate
                                On Error GoTo 0
                                Exit Function
                            End If
                        End If
                    End If
                    Err.Clear
                    On Error GoTo 0
                Next attempt
            End If
        End If
    Next i

    CreateExportRoot = ""
End Function

Private Sub EnsureFolder(ByVal folderPath As String)
    If Len(Dir$(folderPath, vbDirectory)) = 0 Then MkDir folderPath
    If Len(Dir$(folderPath, vbDirectory)) = 0 Then
        Err.Raise vbObjectError + 100, "EnsureFolder", "Could not create folder: " & folderPath
    End If
End Sub

Private Function OpenUtf8Output(ByVal path As String) As Integer
    Dim n As Integer, detail As String
    Dim bom(0 To 2) As Byte
    On Error GoTo Failed
    n = FreeFile
    Open path For Binary Access Write As #n
    bom(0) = &HEF: bom(1) = &HBB: bom(2) = &HBF
    Put #n, , bom
    OpenUtf8Output = n
    Exit Function
Failed:
    detail = Err.Description
    On Error Resume Next
    If n <> 0 Then Close #n
    On Error GoTo 0
    Err.Raise vbObjectError + 104, "OpenUtf8Output", "Could not open " & path & ": " & detail
End Function

Private Sub WriteUtf8(ByVal fileNo As Integer, ByVal text As String)
    Dim bytes() As Byte
    Dim need As Long, written As Long

    If Len(text) = 0 Then Exit Sub

    need = WideCharToMultiByte(CP_UTF8, 0, StrPtr(text), Len(text), 0, 0, 0, 0)
    If need <= 0 Then Err.Raise vbObjectError + 101, "WriteUtf8", "UTF-8 sizing conversion failed."

    ReDim bytes(0 To need - 1)
    written = WideCharToMultiByte(CP_UTF8, 0, StrPtr(text), Len(text), VarPtr(bytes(0)), need, 0, 0)
    If written <= 0 Then Err.Raise vbObjectError + 102, "WriteUtf8", "UTF-8 conversion failed."
    If written <> need Then ReDim Preserve bytes(0 To written - 1)
    Put #fileNo, , bytes
End Sub

Private Sub WriteUtf8Line(ByVal fileNo As Integer, ByVal text As String)
    WriteUtf8 fileNo, text & vbCrLf
End Sub

Private Sub WriteUtf8File(ByVal path As String, ByVal content As String)
    Dim n As Integer, detail As String
    n = OpenUtf8Output(path)
    On Error GoTo Failed
    WriteUtf8 n, content
    Close #n
    Exit Sub
Failed:
    detail = Err.Description
    On Error Resume Next
    Close #n
    On Error GoTo 0
    Err.Raise vbObjectError + 103, "WriteUtf8File", "Could not write " & path & ": " & detail
End Sub

Private Sub CloseExportFiles()
    On Error Resume Next
    If gManifestFN <> 0 Then Close #gManifestFN
    If gAttachmentManifestFN <> 0 Then Close #gAttachmentManifestFN
    If gBinaryManifestFN <> 0 Then Close #gBinaryManifestFN
    If gTableSummaryFN <> 0 Then Close #gTableSummaryFN
    gManifestFN = 0
    gAttachmentManifestFN = 0
    gBinaryManifestFN = 0
    gTableSummaryFN = 0
    On Error GoTo 0
End Sub

'==============================
' SCHEMA EXPORT
'==============================
Private Sub ExportSchema(ByVal db As DAO.Database)
    ExportTableSchema db
    ExportFieldSchema db
    ExportIndexSchema db
    ExportRelationSchema db
End Sub

Private Sub ExportTableSchema(ByVal db As DAO.Database)
    Dim n As Integer, t As DAO.TableDef, tableNo As Long
    On Error GoTo Failed
    n = OpenUtf8Output(gRoot & "\Schema\tables.csv")
    WriteUtf8Line n, CsvRow(Array("Table", "TableToken", "CSVFile", "IsLinked", "SourceTable", _
        "TableAttributes", "Description", "ValidationRule", "ValidationText"))
    tableNo = 0
    For Each t In db.TableDefs
        If Not IsSystemObject(t.Name) Then
            tableNo = tableNo + 1
            WriteTableSchemaRow n, t, tableNo
        End If
    Next t
    Close #n
    LogEvent "Schema", "tables.csv", "OK", "Table metadata export pass completed. Check per-table errors in manifest.csv."
    Exit Sub
Failed:
    On Error Resume Next
    If n <> 0 Then Close #n
    LogEvent "Schema", "tables.csv", "ERROR", Err.Description
End Sub

Private Sub WriteTableSchemaRow(ByVal n As Integer, ByVal t As DAO.TableDef, ByVal tableNo As Long)
    On Error GoTo Failed
    WriteUtf8Line n, CsvRow(Array(t.Name, TableToken(tableNo, t.Name), _
        "Tables\" & TableToken(tableNo, t.Name) & ".csv", (Len(t.Connect) > 0), _
        SafeTableSource(t), t.Attributes, SafeProp(t, "Description"), _
        SafeProp(t, "ValidationRule"), SafeProp(t, "ValidationText")))
    Exit Sub
Failed:
    LogEvent "SchemaTable", t.Name, "ERROR", "Error " & CStr(Err.Number) & ": " & Err.Description
    Err.Clear
End Sub

Private Sub ExportFieldSchema(ByVal db As DAO.Database)
    Dim n As Integer, t As DAO.TableDef, f As DAO.Field
    Dim tableNo As Long, fieldNo As Long
    On Error GoTo Failed
    n = OpenUtf8Output(gRoot & "\Schema\fields.csv")
    WriteUtf8Line n, CsvRow(Array("Table", "TableToken", "Ordinal", "FieldToken", "Field", "DAOType", "TypeName", _
        "Size", "Attributes", "Required", "AllowZeroLength", "DefaultValue", _
        "ValidationRule", "ValidationText", "Description", "Caption", "Format", _
        "InputMask", "DecimalPlaces", "UnicodeCompression", "Expression", "IsComplex", "DisplayControl", _
        "RowSourceType", "RowSource", "BoundColumn", "ColumnCount", "ColumnHeads", _
        "LimitToList", "AllowValueListEdits"))
    tableNo = 0
    For Each t In db.TableDefs
        If Not IsSystemObject(t.Name) Then
            tableNo = tableNo + 1
            fieldNo = 0
            For Each f In t.Fields
                fieldNo = fieldNo + 1
                WriteFieldSchemaRow n, t, f, tableNo, fieldNo
            Next f
        End If
    Next t
    Close #n
    LogEvent "Schema", "fields.csv", "OK", "Field metadata export pass completed. Check per-field errors in manifest.csv."
    Exit Sub
Failed:
    On Error Resume Next
    If n <> 0 Then Close #n
    LogEvent "Schema", "fields.csv", "ERROR", Err.Description
End Sub

Private Sub WriteFieldSchemaRow(ByVal n As Integer, ByVal t As DAO.TableDef, _
    ByVal f As DAO.Field, ByVal tableNo As Long, ByVal fieldNo As Long)
    On Error GoTo Failed
    WriteUtf8Line n, CsvRow(Array(t.Name, TableToken(tableNo, t.Name), fieldNo, _
        FieldToken(fieldNo, f.Name), f.Name, f.Type, DAOTypeName(f.Type), f.Size, f.Attributes, _
        SafeProp(f, "Required"), SafeProp(f, "AllowZeroLength"), SafeProp(f, "DefaultValue"), _
        SafeProp(f, "ValidationRule"), SafeProp(f, "ValidationText"), SafeProp(f, "Description"), _
        SafeProp(f, "Caption"), SafeProp(f, "Format"), SafeProp(f, "InputMask"), _
        SafeProp(f, "DecimalPlaces"), SafeProp(f, "UnicodeCompression"), SafeProp(f, "Expression"), _
        SafeProp(f, "IsComplex"), SafeProp(f, "DisplayControl"), _
        SafeProp(f, "RowSourceType"), SafeProp(f, "RowSource"), SafeProp(f, "BoundColumn"), _
        SafeProp(f, "ColumnCount"), SafeProp(f, "ColumnHeads"), SafeProp(f, "LimitToList"), _
        SafeProp(f, "AllowValueListEdits")))
    Exit Sub
Failed:
    LogEvent "SchemaField", t.Name & "." & f.Name, "ERROR", _
        "Error " & CStr(Err.Number) & ": " & Err.Description
    Err.Clear
End Sub

Private Sub ExportIndexSchema(ByVal db As DAO.Database)
    Dim n As Integer, t As DAO.TableDef
    Dim tableNo As Long
    On Error GoTo Failed
    n = OpenUtf8Output(gRoot & "\Schema\indexes.csv")
    WriteUtf8Line n, CsvRow(Array("Table", "TableToken", "Index", "Primary", "Unique", "Required", "IgnoreNulls", "Attributes", "FieldsJSON"))
    tableNo = 0
    For Each t In db.TableDefs
        If Not IsSystemObject(t.Name) Then
            tableNo = tableNo + 1
            ExportIndexesForTable n, t, tableNo
        End If
    Next t
    Close #n
    LogEvent "Schema", "indexes.csv", "OK", "Index metadata export pass completed. Check per-table errors in manifest.csv."
    Exit Sub
Failed:
    On Error Resume Next
    If n <> 0 Then Close #n
    LogEvent "Schema", "indexes.csv", "ERROR", Err.Description
End Sub

Private Sub ExportIndexesForTable(ByVal n As Integer, ByVal t As DAO.TableDef, ByVal tableNo As Long)
    Dim ix As DAO.Index, detail As String
    On Error GoTo TableIndexFailed
    For Each ix In t.Indexes
        On Error GoTo OneIndexFailed
        WriteUtf8Line n, CsvRow(Array(t.Name, TableToken(tableNo, t.Name), ix.Name, _
            ix.Primary, ix.Unique, SafeProp(ix, "Required"), SafeProp(ix, "IgnoreNulls"), _
            ix.Attributes, IndexFieldsJson(ix)))
        GoTo NextIndex
OneIndexFailed:
        detail = "Error " & CStr(Err.Number) & ": " & Err.Description
        LogEvent "SchemaIndex", t.Name & "." & ix.Name, "ERROR", detail
        Err.Clear
        Resume NextIndex
NextIndex:
        On Error GoTo TableIndexFailed
    Next ix
    Exit Sub
TableIndexFailed:
    detail = "Error " & CStr(Err.Number) & ": " & Err.Description
    LogEvent "SchemaIndex", t.Name, "ERROR", detail
    Err.Clear
End Sub

Private Sub ExportRelationSchema(ByVal db As DAO.Database)
    Dim n As Integer, r As DAO.Relation
    On Error GoTo Failed
    n = OpenUtf8Output(gRoot & "\Schema\relationships.csv")
    WriteUtf8Line n, CsvRow(Array("Relationship", "ParentTable", "ChildTable", "ParentField", "ChildField", "Attributes"))
    For Each r In db.Relations
        If Not IsSystemObject(r.Table) And Not IsSystemObject(r.ForeignTable) Then
            ExportOneRelation n, r
        End If
    Next r
    Close #n
    LogEvent "Schema", "relationships.csv", "OK", "Relationship metadata export pass completed. Check per-relationship errors in manifest.csv."
    Exit Sub
Failed:
    On Error Resume Next
    If n <> 0 Then Close #n
    LogEvent "Schema", "relationships.csv", "ERROR", Err.Description
End Sub

Private Sub ExportOneRelation(ByVal n As Integer, ByVal r As DAO.Relation)
    Dim rf As DAO.Field, detail As String
    On Error GoTo RelationFailed
    For Each rf In r.Fields
        WriteUtf8Line n, CsvRow(Array(r.Name, r.Table, r.ForeignTable, rf.Name, rf.ForeignName, r.Attributes))
    Next rf
    Exit Sub
RelationFailed:
    detail = "Error " & CStr(Err.Number) & ": " & Err.Description
    LogEvent "SchemaRelationship", r.Name, "ERROR", detail
    Err.Clear
End Sub

Private Function SafeTableSource(ByVal t As DAO.TableDef) As String
    On Error GoTo Missing
    If Len(t.Connect) > 0 Then
        SafeTableSource = t.SourceTableName
    Else
        SafeTableSource = ""
    End If
    Exit Function
Missing:
    SafeTableSource = "[UNAVAILABLE]"
End Function

Private Function SafeProp(ByVal obj As Object, ByVal propName As String) As String
    Dim v As Variant
    On Error GoTo Missing
    v = obj.Properties(propName).Value
    If IsNull(v) Then
        SafeProp = ""
    Else
        SafeProp = CStr(v)
    End If
    Exit Function
Missing:
    SafeProp = ""
End Function

Private Function IndexFieldsJson(ByVal ix As DAO.Index) As String
    Dim f As DAO.Field, s As String
    For Each f In ix.Fields
        If Len(s) > 0 Then s = s & ","
        s = s & JsonQuote(f.Name)
    Next f
    IndexFieldsJson = "[" & s & "]"
End Function

Private Function DAOTypeName(ByVal dataType As Long) As String
    Select Case dataType
        Case 1: DAOTypeName = "Boolean"
        Case 2: DAOTypeName = "Byte"
        Case 3: DAOTypeName = "Integer"
        Case 4: DAOTypeName = "Long"
        Case 5: DAOTypeName = "Currency"
        Case 6: DAOTypeName = "Single"
        Case 7: DAOTypeName = "Double"
        Case 8: DAOTypeName = "Date/Time"
        Case 9: DAOTypeName = "Binary"
        Case 10: DAOTypeName = "Short Text"
        Case 11: DAOTypeName = "Long Binary/OLE Object"
        Case 12: DAOTypeName = "Long Text/Memo"
        Case 15: DAOTypeName = "GUID"
        Case 16: DAOTypeName = "Big Integer"
        Case 17: DAOTypeName = "Variable Binary"
        Case 18: DAOTypeName = "Fixed Text/Char"
        Case 19: DAOTypeName = "Numeric"
        Case 20: DAOTypeName = "Decimal"
        Case 21: DAOTypeName = "Float"
        Case 22: DAOTypeName = "Time"
        Case 23: DAOTypeName = "Timestamp"
        Case 26: DAOTypeName = "Date/Time Extended"
        Case 101: DAOTypeName = "Attachment"
        Case 102: DAOTypeName = "Multi-value Byte"
        Case 103: DAOTypeName = "Multi-value Integer"
        Case 104: DAOTypeName = "Multi-value Long"
        Case 105: DAOTypeName = "Multi-value Single"
        Case 106: DAOTypeName = "Multi-value Double"
        Case 107: DAOTypeName = "Multi-value GUID"
        Case 108: DAOTypeName = "Multi-value Decimal"
        Case 109: DAOTypeName = "Multi-value Text"
        Case Else: DAOTypeName = "Unknown/Other"
    End Select
End Function

'==============================
' TABLE DATA EXPORT
'==============================
Private Sub ExportTable(ByVal db As DAO.Database, ByVal t As DAO.TableDef, ByVal tableNo As Long)
    Dim rs As DAO.Recordset, f As DAO.Field
    Dim headers() As Variant, values() As Variant
    Dim i As Long, rowsWritten As Long, rowOrdinal As Long, fileNo As Integer
    Dim beforeErrors As Long, beforeWarnings As Long
    Dim tableName As String, tableCode As String, csvPath As String
    Dim primaryKey As String, detail As String, finalStatus As String
    Dim linked As Boolean, hadCellError As Boolean

    tableName = t.Name
    tableCode = TableToken(tableNo, tableName)
    csvPath = gRoot & "\Tables\" & tableCode & ".csv"
    beforeErrors = gErrors
    beforeWarnings = gWarnings
    rowsWritten = 0
    fileNo = 0
    On Error GoTo TableFailed

    linked = (Len(t.Connect) > 0)
    Set rs = db.OpenRecordset(t.Name, dbOpenSnapshot)
    ReDim headers(0 To rs.Fields.Count - 1)
    For i = 0 To rs.Fields.Count - 1
        headers(i) = rs.Fields(i).Name
    Next i

    fileNo = OpenUtf8Output(csvPath)
    WriteUtf8Line fileNo, CsvRow(headers)

    Do While Not rs.EOF
        rowOrdinal = rowsWritten + 1
        primaryKey = PrimaryKeyJson(t, rs)
        ReDim values(0 To rs.Fields.Count - 1)

        For i = 0 To rs.Fields.Count - 1
            Set f = rs.Fields(i)
            hadCellError = False
            values(i) = ExportCell(f, t, tableNo, i + 1, rowOrdinal, primaryKey, hadCellError)
        Next i

        WriteUtf8Line fileNo, CsvRow(values)
        rowsWritten = rowOrdinal
        rs.MoveNext
    Loop

    Close #fileNo
    fileNo = 0
    rs.Close
    Set rs = Nothing

    If gErrors > beforeErrors Then
        finalStatus = "PARTIAL"
    ElseIf gWarnings > beforeWarnings Then
        finalStatus = "PARTIAL"
    Else
        finalStatus = "OK"
    End If

    LogEvent "Table", tableName, finalStatus, CStr(rowsWritten) & " row(s) written; file=" & csvPath
    WriteUtf8Line gTableSummaryFN, CsvRow(Array(tableName, "Tables\" & tableCode & ".csv", linked, rowsWritten, finalStatus, "See manifest.csv for field-level issues."))
    Exit Sub

TableFailed:
    detail = "Error " & CStr(Err.Number) & ": " & Err.Description
    On Error Resume Next
    If fileNo <> 0 Then Close #fileNo
    If Not rs Is Nothing Then rs.Close
    LogEvent "Table", tableName, "ERROR", detail
    WriteUtf8Line gTableSummaryFN, CsvRow(Array(tableName, "Tables\" & tableCode & ".csv", linked, rowsWritten, "FAILED", detail))
    On Error GoTo 0
End Sub

Private Function ExportCell(ByVal f As DAO.Field, ByVal t As DAO.TableDef, _
    ByVal tableNo As Long, ByVal fieldNo As Long, ByVal rowNo As Long, _
    ByVal primaryKey As String, ByRef hadError As Boolean) As Variant

    Dim v As Variant, tableCode As String, fieldCode As String
    On Error GoTo CellFailed

    tableCode = TableToken(tableNo, t.Name)
    fieldCode = FieldToken(fieldNo, f.Name)

    Select Case f.Type
        Case 101
            ExportCell = ExportAttachmentField(f, t.Name, f.Name, tableCode, fieldCode, rowNo, primaryKey)
        Case 102 To 109
            ExportCell = ExportMultiValueField(f, t.Name, f.Name, rowNo, primaryKey)
        Case 11
            ' FieldSize avoids loading an entire large OLE value into memory.
            If f.FieldSize = 0 Then
                v = f.Value
                If IsNull(v) Then
                    ExportCell = Null
                Else
                    ExportCell = ExportLongBinaryField(f, t.Name, f.Name, tableCode, fieldCode, rowNo, primaryKey)
                End If
            Else
                ExportCell = ExportLongBinaryField(f, t.Name, f.Name, tableCode, fieldCode, rowNo, primaryKey)
            End If
        Case 9, 17
            v = f.Value
            If IsArray(v) Then
                ExportCell = ExportSimpleBinaryValue(v, t.Name, f.Name, tableCode, fieldCode, rowNo, primaryKey)
            ElseIf IsNull(v) Then
                ExportCell = Null
            Else
                ExportCell = ExportSimpleBinaryValue(v, t.Name, f.Name, tableCode, fieldCode, rowNo, primaryKey)
            End If
        Case Else
            v = f.Value
            If IsNull(v) Then
                ExportCell = Null
            Else
                ExportCell = ScalarText(v, f.Type)
            End If
    End Select
    Exit Function

CellFailed:
    hadError = True
    LogEvent "Field", t.Name & "." & f.Name & " [row " & CStr(rowNo) & "]", "ERROR", _
             "Error " & CStr(Err.Number) & ": " & Err.Description
    Err.Clear
    ExportCell = "[EXPORT ERROR - see manifest.csv]"
End Function

Private Function ExportAttachmentField(ByVal f As DAO.Field, ByVal tableName As String, _
    ByVal fieldName As String, ByVal tableCode As String, ByVal fieldCode As String, _
    ByVal rowNo As Long, ByVal primaryKey As String) As Variant

    Dim child As Object
    Dim originalName As String, safeName As String, folderPath As String
    Dim fullPath As String, relativePath As String, items As String, detail As String
    Dim attachmentNo As Long, fieldFailed As Boolean

    On Error GoTo ComplexFailed
    Set child = f.Value
    If child.BOF And child.EOF Then
        ExportAttachmentField = "[]"
        GoTo CleanUp
    End If
    If Not child.BOF Then child.MoveFirst

    Do While Not child.EOF
        attachmentNo = attachmentNo + 1
        originalName = "attachment_" & Format$(attachmentNo, "000") & ".bin"

        On Error GoTo OneAttachmentFailed
        If Not IsNull(child.Fields("FileName").Value) Then
            originalName = CStr(child.Fields("FileName").Value)
        End If
        safeName = SafeAttachmentName(originalName)
        folderPath = gRoot & "\Attachments\" & tableCode & "\" & fieldCode & "\R" & Format$(rowNo, "00000000")
        EnsureFolder gRoot & "\Attachments\" & tableCode
        EnsureFolder gRoot & "\Attachments\" & tableCode & "\" & fieldCode
        EnsureFolder folderPath
        fullPath = UniqueFilePath(folderPath & "\A" & Format$(attachmentNo, "000") & "__" & safeName)
        child.Fields("FileData").SaveToFile fullPath
        relativePath = RelativePath(fullPath)
        WriteUtf8Line gAttachmentManifestFN, CsvRow(Array(tableName, fieldName, rowNo, primaryKey, attachmentNo, originalName, relativePath, "OK", ""))
        If Len(items) > 0 Then items = items & ","
        items = items & JsonQuote(relativePath)
        GoTo AttachmentNext

OneAttachmentFailed:
        fieldFailed = True
        detail = "Error " & CStr(Err.Number) & ": " & Err.Description
        LogEvent "Attachment", tableName & "." & fieldName & " [row " & CStr(rowNo) & ", item " & CStr(attachmentNo) & "]", "ERROR", detail
        WriteAttachmentManifestSafe Array(tableName, fieldName, rowNo, primaryKey, attachmentNo, originalName, "", "ERROR", detail)
        Err.Clear
        Resume AttachmentNext

AttachmentNext:
        On Error GoTo ComplexFailed
        child.MoveNext
    Loop

    If fieldFailed Then LogEvent "AttachmentField", tableName & "." & fieldName & " [row " & CStr(rowNo) & "]", "PARTIAL", "One or more attachments failed; see attachment manifest."
    ExportAttachmentField = "[" & items & "]"
    GoTo CleanUp

ComplexFailed:
    detail = "Error " & CStr(Err.Number) & ": " & Err.Description
    LogEvent "AttachmentField", tableName & "." & fieldName & " [row " & CStr(rowNo) & "]", "ERROR", detail
    ExportAttachmentField = "[" & items & "]"

CleanUp:
    On Error Resume Next
    If Not child Is Nothing Then child.Close
    Set child = Nothing
End Function

Private Sub WriteAttachmentManifestSafe(ByVal values As Variant)
    On Error Resume Next
    If gAttachmentManifestFN <> 0 Then WriteUtf8Line gAttachmentManifestFN, CsvRow(values)
    On Error GoTo 0
End Sub

Private Function ExportMultiValueField(ByVal f As DAO.Field, ByVal tableName As String, _
    ByVal fieldName As String, ByVal rowNo As Long, ByVal primaryKey As String) As String

    Dim child As Object, valueField As Object
    Dim items As String, detail As String

    On Error GoTo MultiFailed
    Set child = f.Value
    If child.BOF And child.EOF Then
        ExportMultiValueField = "[]"
        GoTo CleanUp
    End If
    If Not child.BOF Then child.MoveFirst

    Do While Not child.EOF
        On Error Resume Next
        Set valueField = child.Fields("Value")
        If Err.Number <> 0 Then
            Err.Clear
            Set valueField = child.Fields(0)
        End If
        On Error GoTo MultiFailed

        If Len(items) > 0 Then items = items & ","
        items = items & JsonTypedValue(valueField.Value, valueField.Type)
        child.MoveNext
    Loop
    ExportMultiValueField = "[" & items & "]"
    GoTo CleanUp

MultiFailed:
    detail = "Error " & CStr(Err.Number) & ": " & Err.Description
    LogEvent "MultiValueField", tableName & "." & fieldName & " [row " & CStr(rowNo) & "]", "ERROR", detail
    ExportMultiValueField = "[" & JsonQuote("[EXPORT ERROR]") & "]"
CleanUp:
    On Error Resume Next
    If Not child Is Nothing Then child.Close
    Set child = Nothing
End Function

Private Function ExportLongBinaryField(ByVal f As DAO.Field, ByVal tableName As String, _
    ByVal fieldName As String, ByVal tableCode As String, ByVal fieldCode As String, _
    ByVal rowNo As Long, ByVal primaryKey As String) As String

    Dim folderPath As String, fullPath As String, relativePath As String
    Dim fileNo As Integer, totalSize As Long, offset As Long, requestBytes As Long, actualBytes As Long
    Dim chunk As Variant, usedStringFallback As Boolean, detail As String
    Dim fileOpen As Boolean

    On Error GoTo BinaryFailed
    folderPath = gRoot & "\Binary\" & tableCode & "\" & fieldCode
    EnsureFolder gRoot & "\Binary\" & tableCode
    EnsureFolder folderPath
    fullPath = UniqueFilePath(folderPath & "\R" & Format$(rowNo, "00000000") & ".bin")
    totalSize = f.FieldSize

    fileNo = FreeFile
    Open fullPath For Binary Access Write As #fileNo
    fileOpen = True
    offset = 0
    Do While offset < totalSize
        requestBytes = totalSize - offset
        If requestBytes > CHUNK_SIZE Then requestBytes = CHUNK_SIZE
        chunk = f.GetChunk(offset, requestBytes)
        actualBytes = WriteVariantBytes(fileNo, chunk, usedStringFallback)
        If actualBytes <= 0 Then Err.Raise vbObjectError + 201, "ExportLongBinaryField", "GetChunk returned no bytes before FieldSize was reached."
        If actualBytes > requestBytes Then Err.Raise vbObjectError + 202, "ExportLongBinaryField", "Chunk was larger than requested."
        offset = offset + actualBytes
    Loop

    Close #fileNo
    fileOpen = False
    relativePath = RelativePath(fullPath)
    WriteUtf8Line gBinaryManifestFN, CsvRow(Array("LongBinary/OLE", tableName, fieldName, rowNo, primaryKey, relativePath, totalSize, "OK", IIf(usedStringFallback, "DAO returned string chunks; low-byte fallback used; verify byte-for-byte.", "")))
    If usedStringFallback Then LogEvent "Binary", tableName & "." & fieldName & " [row " & CStr(rowNo) & "]", "WARN", "DAO returned String chunks; low-byte fallback used. Verify this binary export before relying on it."
    ExportLongBinaryField = "[BINARY_FILE:" & relativePath & "]"
    Exit Function

BinaryFailed:
    detail = "Error " & CStr(Err.Number) & ": " & Err.Description
    On Error Resume Next
    If fileOpen Then Close #fileNo
    WriteUtf8Line gBinaryManifestFN, CsvRow(Array("LongBinary/OLE", tableName, fieldName, rowNo, primaryKey, RelativePath(fullPath), 0, "ERROR", detail))
    On Error GoTo 0
    LogEvent "Binary", tableName & "." & fieldName & " [row " & CStr(rowNo) & "]", "ERROR", detail
    ExportLongBinaryField = "[BINARY EXPORT ERROR - see binary_manifest.csv]"
End Function

Private Function ExportSimpleBinaryValue(ByVal v As Variant, ByVal tableName As String, _
    ByVal fieldName As String, ByVal tableCode As String, ByVal fieldCode As String, _
    ByVal rowNo As Long, ByVal primaryKey As String) As String

    Dim folderPath As String, fullPath As String, relativePath As String
    Dim fileNo As Integer, fileOpen As Boolean
    Dim usedStringFallback As Boolean, bytesWritten As Long, detail As String

    On Error GoTo BinaryFailed
    folderPath = gRoot & "\Binary\" & tableCode & "\" & fieldCode
    EnsureFolder gRoot & "\Binary\" & tableCode
    EnsureFolder folderPath
    fullPath = UniqueFilePath(folderPath & "\R" & Format$(rowNo, "00000000") & ".bin")
    fileNo = FreeFile
    Open fullPath For Binary Access Write As #fileNo
    fileOpen = True
    bytesWritten = WriteVariantBytes(fileNo, v, usedStringFallback)
    Close #fileNo
    fileOpen = False
    relativePath = RelativePath(fullPath)
    WriteUtf8Line gBinaryManifestFN, CsvRow(Array("Binary", tableName, fieldName, rowNo, primaryKey, relativePath, bytesWritten, "OK", IIf(usedStringFallback, "String-to-byte fallback used; verify binary fidelity.", "")))
    If usedStringFallback Then LogEvent "Binary", tableName & "." & fieldName & " [row " & CStr(rowNo) & "]", "WARN", "Binary value was a String; low-byte fallback used. Verify the file."
    ExportSimpleBinaryValue = "[BINARY_FILE:" & relativePath & "]"
    Exit Function

BinaryFailed:
    detail = "Error " & CStr(Err.Number) & ": " & Err.Description
    On Error Resume Next
    If fileOpen Then Close #fileNo
    If gBinaryManifestFN <> 0 Then WriteUtf8Line gBinaryManifestFN, CsvRow(Array("Binary", tableName, fieldName, rowNo, primaryKey, RelativePath(fullPath), 0, "ERROR", detail))
    On Error GoTo 0
    LogEvent "Binary", tableName & "." & fieldName & " [row " & CStr(rowNo) & "]", "ERROR", detail
    ExportSimpleBinaryValue = "[BINARY EXPORT ERROR - see binary_manifest.csv]"
End Function

Private Function WriteVariantBytes(ByVal fileNo As Integer, ByVal data As Variant, _
    ByRef usedStringFallback As Boolean) As Long

    Dim bytes() As Byte, i As Long, lo As Long, hi As Long, s As String

    If IsArray(data) Then
        lo = LBound(data)
        hi = UBound(data)
        If hi < lo Then Exit Function
        ReDim bytes(0 To hi - lo)
        For i = lo To hi
            bytes(i - lo) = CByte(CLng(data(i)) And &HFF&)
        Next i
        Put #fileNo, , bytes
        WriteVariantBytes = UBound(bytes) + 1
    ElseIf VarType(data) = vbString Then
        s = CStr(data)
        If Len(s) = 0 Then Exit Function
        ReDim bytes(0 To Len(s) - 1)
        For i = 1 To Len(s)
            bytes(i - 1) = CByte(AscW(Mid$(s, i, 1)) And &HFF&)
        Next i
        Put #fileNo, , bytes
        usedStringFallback = True
        WriteVariantBytes = Len(s)
    Else
        Err.Raise vbObjectError + 203, "WriteVariantBytes", "Unsupported binary chunk type: " & TypeName(data)
    End If
End Function

'==============================
' QUERIES AND OTHER ACCESS OBJECTS
'==============================
Private Sub ExportQuery(ByVal q As DAO.QueryDef, ByVal queryNo As Long)
    Dim baseName As String, sqlPath As String, objectPath As String, detail As String

    baseName = "Q" & Format$(queryNo, "0000") & "_" & SafeToken(q.Name, 20)
    sqlPath = gRoot & "\Queries\" & baseName & ".sql"
    objectPath = gRoot & "\Queries\" & baseName & ".txt"

    On Error GoTo SqlFailed
    WriteUtf8File sqlPath, q.SQL & vbCrLf
    LogEvent "QuerySQL", q.Name, "OK", "SQL written to " & sqlPath

    On Error Resume Next
    Err.Clear
    Application.SaveAsText acQuery, q.Name, objectPath
    If Err.Number <> 0 Then
        detail = Err.Description
        LogEvent "QueryDefinition", q.Name, "WARN", "SQL exported, but SaveAsText failed: " & detail
    Else
        LogEvent "QueryDefinition", q.Name, "OK", "Access query object text exported."
    End If
    Err.Clear
    On Error GoTo 0
    Exit Sub

SqlFailed:
    detail = "Error " & CStr(Err.Number) & ": " & Err.Description
    LogEvent "QuerySQL", q.Name, "ERROR", detail
End Sub

Private Sub ExportAccessObject(ByVal objectType As AcObjectType, ByVal objectName As String, _
    ByVal folderName As String, ByVal prefix As String, ByVal objectNo As Long)

    Dim path As String, detail As String
    path = gRoot & "\" & folderName & "\" & prefix & Format$(objectNo, "0000") & "_" & SafeToken(objectName, 24) & ".txt"

    On Error GoTo Failed
    Application.SaveAsText objectType, objectName, path
    LogEvent folderName, objectName, "OK", "Object text exported to " & path
    Exit Sub
Failed:
    detail = "Error " & CStr(Err.Number) & ": " & Err.Description
    LogEvent folderName, objectName, "ERROR", detail
    Err.Clear
End Sub

'==============================
' VALUE SERIALIZATION
'==============================
Private Function ScalarText(ByVal v As Variant, ByVal dataType As Long) As String
    Dim s As String

    Select Case dataType
        Case 1
            If CBool(v) Then ScalarText = "TRUE" Else ScalarText = "FALSE"
        Case 2, 3, 4, 5, 6, 7, 16, 19, 20, 21
            ScalarText = InvariantNumber(v)
        Case 8
            ScalarText = ISODateTimeText(v)
        Case 22, 23
            If IsDate(v) Then
                ScalarText = ISODateTimeText(v)
            Else
                ScalarText = CStr(v)
            End If
        Case 26
            ' Date/Time Extended may have precision/range beyond VBA Date; preserve Access' string rendering.
            ScalarText = CStr(v)
        Case Else
            If IsArray(v) Or IsObject(v) Then
                ScalarText = "[UNSUPPORTED VALUE]"
            Else
                s = CStr(v)
                ScalarText = s
            End If
    End Select
End Function

Private Function InvariantNumber(ByVal v As Variant) As String
    ' CStr preserves Currency/Decimal precision; normalize only the locale decimal separator.
    Dim s As String, decimalSep As String
    s = CStr(v)
    decimalSep = WindowsDecimalSeparator()
    If Len(decimalSep) > 0 And decimalSep <> "." Then s = Replace(s, decimalSep, ".")
    InvariantNumber = s
End Function

Private Function WindowsDecimalSeparator() As String
    Dim buffer As String, n As Long
    On Error GoTo Fallback
    buffer = String$(8, vbNullChar)
    n = GetLocaleInfoW(LOCALE_USER_DEFAULT, LOCALE_SDECIMAL, StrPtr(buffer), Len(buffer))
    If n > 1 Then
        WindowsDecimalSeparator = Left$(buffer, n - 1)
    Else
        WindowsDecimalSeparator = "."
    End If
    Exit Function
Fallback:
    WindowsDecimalSeparator = "."
End Function

Private Function ISODateTimeText(ByVal v As Variant) As String
    Dim d As Date, serial As Double, millis As Long
    d = CDate(v)
    serial = CDbl(d)
    millis = CLng(Int(Abs(serial - Fix(serial)) * 86400000#)) Mod 1000
    ISODateTimeText = Format$(Year(d), "0000") & "-" & _
        Format$(Month(d), "00") & "-" & Format$(Day(d), "00") & "T" & _
        Format$(Hour(d), "00") & ":" & Format$(Minute(d), "00") & ":" & _
        Format$(Second(d), "00")
    If millis > 0 Then ISODateTimeText = ISODateTimeText & "." & Format$(millis, "000")
End Function

Private Function JsonTypedValue(ByVal v As Variant, ByVal dataType As Long) As String
    If IsNull(v) Then
        JsonTypedValue = "null"
        Exit Function
    End If

    Select Case dataType
        Case 1
            If CBool(v) Then JsonTypedValue = "true" Else JsonTypedValue = "false"
        Case 2, 3, 4, 5, 6, 7, 16, 19, 20, 21
            JsonTypedValue = InvariantNumber(v)
        Case 8, 22, 23
            If IsDate(v) Then
                JsonTypedValue = JsonQuote(ISODateTimeText(v))
            Else
                JsonTypedValue = JsonQuote(CStr(v))
            End If
        Case Else
            JsonTypedValue = JsonQuote(ScalarText(v, dataType))
    End Select
End Function

Private Function JsonQuote(ByVal s As String) As String
    Dim i As Long, code As Long, ch As String, out As String
    For i = 1 To Len(s)
        ch = Mid$(s, i, 1)
        code = AscW(ch)
        Select Case code
            Case 34: out = out & Chr$(92) & Chr$(34)
            Case 92: out = out & Chr$(92) & Chr$(92)
            Case 8: out = out & Chr$(92) & "b"
            Case 9: out = out & Chr$(92) & "t"
            Case 10: out = out & Chr$(92) & "n"
            Case 12: out = out & Chr$(92) & "f"
            Case 13: out = out & Chr$(92) & "r"
            Case Else
                If code >= 0 And code < 32 Then
                    out = out & Chr$(92) & "u00" & Right$("0" & Hex$(code), 2)
                Else
                    out = out & ch
                End If
        End Select
    Next i
    JsonQuote = Chr$(34) & out & Chr$(34)
End Function

Private Function CsvRow(ByVal values As Variant) As String
    Dim i As Long, s As String, v As Variant
    For i = LBound(values) To UBound(values)
        If i > LBound(values) Then s = s & ","
        v = values(i)
        If IsNull(v) Then
            ' Null marker is deliberately unquoted; a literal text value "\N" is quoted.
            s = s & "\N"
        Else
            s = s & Chr$(34) & Replace(CStr(v), Chr$(34), Chr$(34) & Chr$(34)) & Chr$(34)
        End If
    Next i
    CsvRow = s
End Function

Private Function PrimaryKeyJson(ByVal t As DAO.TableDef, ByVal rs As DAO.Recordset) As String
    Dim ix As DAO.Index, ixField As DAO.Field, rowField As DAO.Field
    Dim s As String, v As Variant

    On Error GoTo NoKey
    For Each ix In t.Indexes
        If ix.Primary Then
            For Each ixField In ix.Fields
                Set rowField = rs.Fields(ixField.Name)
                v = rowField.Value
                If Len(s) > 0 Then s = s & ","
                s = s & JsonQuote(rowField.Name) & ":" & JsonTypedValue(v, rowField.Type)
            Next ixField
            PrimaryKeyJson = "{" & s & "}"
            Exit Function
        End If
    Next ix
NoKey:
    PrimaryKeyJson = ""
End Function

'==============================
' PATH / CSV / LOG HELPERS
'==============================
Private Function TableToken(ByVal tableNo As Long, ByVal tableName As String) As String
    TableToken = "T" & Format$(tableNo, "0000") & "_" & SafeToken(tableName, 16)
End Function

Private Function FieldToken(ByVal fieldNo As Long, ByVal fieldName As String) As String
    FieldToken = "F" & Format$(fieldNo, "000") & "_" & SafeToken(fieldName, 14)
End Function

Private Function SafeToken(ByVal raw As String, ByVal maxLen As Long) As String
    Dim i As Long, ch As String, s As String
    For i = 1 To Len(raw)
        ch = Mid$(raw, i, 1)
        If AscW(ch) < 32 Or InStr(1, "\/:*?""<>|", ch, vbBinaryCompare) > 0 Then
            s = s & "_"
        Else
            s = s & ch
        End If
    Next i
    s = Trim$(s)
    Do While Len(s) > 0 And (Right$(s, 1) = "." Or Right$(s, 1) = " ")
        s = Left$(s, Len(s) - 1)
    Loop
    If Len(s) = 0 Then s = "unnamed"
    If Len(s) > maxLen Then s = Left$(s, maxLen)
    SafeToken = s
End Function

Private Function SafeAttachmentName(ByVal raw As String) As String
    Dim s As String, ext As String, p As Long
    s = SafeToken(raw, 60)
    p = InStrRev(s, ".")
    If p > 1 And Len(s) > 36 Then
        ext = Mid$(s, p)
        If Len(ext) <= 12 Then s = Left$(s, 36 - Len(ext)) & ext
    End If
    If Len(s) = 0 Then s = "attachment.bin"
    SafeAttachmentName = s
End Function

Private Function UniqueFilePath(ByVal proposedPath As String) As String
    Dim base As String, ext As String, p As Long, i As Long, candidate As String
    If Len(Dir$(proposedPath)) = 0 Then
        UniqueFilePath = proposedPath
        Exit Function
    End If
    p = InStrRev(proposedPath, ".")
    If p > InStrRev(proposedPath, "\") Then
        base = Left$(proposedPath, p - 1)
        ext = Mid$(proposedPath, p)
    Else
        base = proposedPath
        ext = ""
    End If
    For i = 1 To 9999
        candidate = base & "_" & Format$(i, "0000") & ext
        If Len(Dir$(candidate)) = 0 Then
            UniqueFilePath = candidate
            Exit Function
        End If
    Next i
    Err.Raise vbObjectError + 301, "UniqueFilePath", "Could not generate a unique filename for: " & proposedPath
End Function

Private Function RelativePath(ByVal fullPath As String) As String
    If Len(fullPath) > Len(gRoot) Then
        RelativePath = Mid$(fullPath, Len(gRoot) + 2)
    Else
        RelativePath = fullPath
    End If
End Function

Private Function IsSystemObject(ByVal objectName As String) As Boolean
    IsSystemObject = (LCase$(Left$(objectName, 4)) = "msys" Or Left$(objectName, 1) = "~")
End Function

Private Sub LogEvent(ByVal objectType As String, ByVal objectName As String, _
    ByVal status As String, ByVal details As String)

    If UCase$(status) = "ERROR" Or UCase$(status) = "FAILED" Then
        gErrors = gErrors + 1
    ElseIf UCase$(status) = "WARN" Or UCase$(status) = "WARNINGS" Or UCase$(status) = "PARTIAL" Then
        gWarnings = gWarnings + 1
    End If

    If gManifestFN <> 0 Then
        On Error Resume Next
        WriteUtf8Line gManifestFN, CsvRow(Array(Format$(Now, "yyyy-mm-dd hh:nn:ss"), _
            objectType, objectName, status, Replace(Replace(details, vbCr, " "), vbLf, " ")))
        On Error GoTo 0
    End If
End Sub

Private Sub WriteReadme()
    Dim s As String
    s = "Microsoft Access export snapshot" & vbCrLf & _
        "Created: " & Format$(Now, "yyyy-mm-dd hh:nn:ss") & vbCrLf & _
        "Source file: " & CurrentProject.FullName & vbCrLf & vbCrLf & _
        "Folders:" & vbCrLf & _
        "Tables: one UTF-8 CSV per accessible non-system table." & vbCrLf & _
        "Schema: table, field, index, relationship metadata and table export summary." & vbCrLf & _
        "Attachments: extracted files from Attachment fields plus attachments_manifest.csv." & vbCrLf & _
        "Binary: extracted Long Binary/OLE and binary fields where DAO exposes their bytes, plus binary_manifest.csv." & vbCrLf & _
        "Queries: query SQL and, where Access permits it, SaveAsText object definitions." & vbCrLf & _
        "Forms/Reports/Macros/Modules: SaveAsText object definitions where supported." & vbCrLf & _
        "manifest.csv records successes, warnings, partial exports and errors." & vbCrLf & vbCrLf & _
        "CSV encoding: UTF-8 with BOM. CSV values are quoted; embedded quotes are doubled." & vbCrLf & _
        "Null values are written as the unquoted token \N. Empty strings are written as quoted empty strings." & vbCrLf & _
        "Attachment and multi-value cells are JSON arrays. Binary fields are represented by a path marker." & vbCrLf & vbCrLf & _
        "Limitations: this is a best-effort file export, not a restorable Access backup or a migration script." & vbCrLf & _
        "Linked tables are exported only if their sources are accessible. Calculated fields, complex lookup behavior," & vbCrLf & _
        "permissions, relationships' enforcement semantics, startup configuration, and all application behavior may" & vbCrLf & _
        "not be fully recreated by these files. Date/Time Extended and OLE binary values need extra verification." & vbCrLf & _
        "Keep the original ACCDB/MDB unchanged and verify all counts and any ERROR/WARN entries before relying on this export." & vbCrLf
    WriteUtf8File gRoot & "\README.txt", s
End Sub
