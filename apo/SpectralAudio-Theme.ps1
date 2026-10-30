# Colors and typography from the virtual sound-card edition (windows/ui.hpp).
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
if(-not ('SpectralTheme.Card' -as [type])){
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using System.Runtime.InteropServices;
namespace SpectralTheme {
 public class Card : Panel {
  public Card(){DoubleBuffered=true; BackColor=Color.FromArgb(17,21,25);}
  protected override void OnPaint(PaintEventArgs e){base.OnPaint(e); e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
   using(var p=new GraphicsPath()){float w=Width-1,h=Height-1,d=20;
    p.AddArc(0,0,d,d,180,90);p.AddArc(w-d,0,d,d,270,90);p.AddArc(w-d,h-d,d,d,0,90);p.AddArc(0,h-d,d,d,90,90);p.CloseFigure();
    using(var b=new SolidBrush(Color.FromArgb(25,30,35)))e.Graphics.FillPath(b,p);
    using(var pen=new Pen(Color.FromArgb(47,56,63)))e.Graphics.DrawPath(pen,p);}}
 }
 public class Progress : Control {
  Timer timer=new Timer();int offset;
  public Progress(){SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer,true);timer.Interval=30;timer.Tick+=(s,e)=>{offset=(offset+4)%Math.Max(1,Width+120);Invalidate();};timer.Start();}
  protected override void OnPaint(PaintEventArgs e){e.Graphics.Clear(Color.FromArgb(33,40,46));using(var b=new SolidBrush(Color.FromArgb(115,229,192)))e.Graphics.FillRectangle(b,offset-120,0,120,Height);}
  protected override void Dispose(bool disposing){if(disposing)timer.Dispose();base.Dispose(disposing);}
 }
 public static class Native {
  [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h,int a,ref int v,int s);
  public static void Dark(IntPtr h){try{int v=1;DwmSetWindowAttribute(h,20,ref v,4);}catch{}}
 }
}
'@
}
$script:SpectralBackground=[Drawing.Color]::FromArgb(17,21,25)
$script:SpectralPanel=[Drawing.Color]::FromArgb(25,30,35)
$script:SpectralField=[Drawing.Color]::FromArgb(33,40,46)
$script:SpectralInk=[Drawing.Color]::FromArgb(232,239,241)
$script:SpectralMuted=[Drawing.Color]::FromArgb(151,166,175)
$script:SpectralAccent=[Drawing.Color]::FromArgb(115,229,192)
function New-SpectralCard($parent,[int]$x,[int]$y,[int]$w,[int]$h){
 $c=New-Object SpectralTheme.Card;$c.SetBounds($x,$y,$w,$h);$parent.Controls.Add($c);$c.SendToBack();return $c
}
function Set-SpectralTheme($root,$primary){
 $root.BackColor=$script:SpectralBackground;$root.ForeColor=$script:SpectralInk
 $controls=@($root.Controls)
 $cards=@($controls | Where-Object {$_ -is [SpectralTheme.Card]})
 foreach($c in $controls){
  if($c -isnot [SpectralTheme.Card]){
   foreach($card in $cards){
    if($card.Bounds.Contains($c.Bounds)){
     $location=New-Object Drawing.Point(($c.Left-$card.Left),($c.Top-$card.Top))
     $c.Parent=$card;$c.Location=$location;break
    }
   }
  }
  $c.ForeColor=$script:SpectralInk
  if($c -is [Windows.Forms.Button]){
   $c.FlatStyle='Flat';$c.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(47,56,63);$c.BackColor=$script:SpectralField
   $c.FlatAppearance.MouseOverBackColor=[Drawing.Color]::FromArgb(42,71,64)
   if($c -eq $primary){$c.BackColor=$script:SpectralAccent;$c.ForeColor=$script:SpectralBackground;$c.FlatAppearance.MouseOverBackColor=[Drawing.Color]::FromArgb(145,242,211)}
  }elseif($c -is [Windows.Forms.ComboBox]){
   $c.BackColor=$script:SpectralField;$c.FlatStyle='Flat';$c.DrawMode='OwnerDrawFixed';$c.ItemHeight=26
   $c.Add_DrawItem({param($sender,$e)
    if($e.Index -lt 0){return};$selected=($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
    $bg=if($selected){[Drawing.Color]::FromArgb(42,71,64)}else{$script:SpectralField};$fg=if($selected){$script:SpectralAccent}else{$script:SpectralInk}
    $b=New-Object Drawing.SolidBrush($bg);$e.Graphics.FillRectangle($b,$e.Bounds);$b.Dispose()
    $r=$e.Bounds;$r.X+=8;$r.Width-=8
    [Windows.Forms.TextRenderer]::DrawText($e.Graphics,[string]$sender.Items[$e.Index],$e.Font,$r,$fg,([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis));$e.DrawFocusRectangle()
   })
  }elseif($c -is [Windows.Forms.TextBox] -or $c -is [Windows.Forms.NumericUpDown]){$c.BackColor=$script:SpectralField
  }elseif($c -is [Windows.Forms.CheckBox]){$c.BackColor=$script:SpectralPanel
  }elseif($c -is [Windows.Forms.Label]){
   $c.BackColor=$script:SpectralPanel
   if($c.Tag -eq 'header'){$c.BackColor=$script:SpectralBackground;$c.ForeColor=$script:SpectralAccent}
   elseif($c.Tag -eq 'muted'){$c.ForeColor=$script:SpectralMuted}
  }
 }
 $root.Add_HandleCreated({param($sender,$e) [SpectralTheme.Native]::Dark($sender.Handle)})
}
function Add-SpectralHeader($form,[string]$subtitle){
 $logo=New-Object Windows.Forms.Label;$logo.Text='Spectral';$logo.SetBounds(24,22,46,46);$logo.TextAlign='MiddleCenter';$logo.Font=New-Object Drawing.Font('Microsoft YaHei UI',17,[Drawing.FontStyle]::Bold)
 $form.Controls.Add($logo);$logo.BackColor=$script:SpectralAccent;$logo.ForeColor=$script:SpectralBackground
 $name=New-Object Windows.Forms.Label;$name.Text='Spectral AUDIO';$name.SetBounds(86,17,270,32);$name.Font=New-Object Drawing.Font('Microsoft YaHei UI',18,[Drawing.FontStyle]::Bold);$name.BackColor=$script:SpectralBackground;$name.ForeColor=$script:SpectralInk;$form.Controls.Add($name)
 $sub=New-Object Windows.Forms.Label;$sub.Text=$subtitle;$sub.SetBounds(87,53,620,24);$sub.Font=New-Object Drawing.Font('Microsoft YaHei UI',9);$sub.BackColor=$script:SpectralBackground;$sub.ForeColor=$script:SpectralMuted;$form.Controls.Add($sub)
}
