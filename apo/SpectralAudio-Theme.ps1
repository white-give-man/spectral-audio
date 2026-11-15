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
 public class EqFrequencyInput : TextBox {
  protected override bool IsInputKey(Keys keyData) {
   Keys key=keyData&Keys.KeyCode;
   return key==Keys.Enter||key==Keys.Escape||base.IsInputKey(keyData);
  }
 }
 public class EqFader : Control {
  int gain;
  static readonly Color Surface=Color.FromArgb(25,30,35);
  static readonly Color Accent=Color.FromArgb(115,229,192);
  static readonly Color Muted=Color.FromArgb(115,132,141);
  public event EventHandler ValueChanged;
  public EqFader(){
   SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer|ControlStyles.Selectable,true);
   TabStop=true; Cursor=Cursors.Hand; AccessibleRole=AccessibleRole.Slider;
  }
  public int Value {
   get { return gain; }
   set {
    int next=Math.Max(-600,Math.Min(600,value));
    if(gain==next)return;
    gain=next;Invalidate();if(ValueChanged!=null)ValueChanged(this,EventArgs.Empty);
   }
  }
  int Inset { get { return Math.Max(8,Width/6); } }
  int Travel { get { return Math.Max(1,Height-2*Inset-1); } }
  void MoveTo(int y) { Value=10*(int)Math.Round(60-(y-Inset)*120.0/Travel); }
  protected override void OnMouseDown(MouseEventArgs e){
   base.OnMouseDown(e);if(e.Button==MouseButtons.Left){Focus();Capture=true;MoveTo(e.Y);}
  }
  protected override void OnMouseMove(MouseEventArgs e){base.OnMouseMove(e);if(Capture)MoveTo(e.Y);}
  protected override void OnMouseUp(MouseEventArgs e){base.OnMouseUp(e);if(e.Button==MouseButtons.Left)Capture=false;}
  protected override void OnMouseWheel(MouseEventArgs e){base.OnMouseWheel(e);if(Focused)Value+=10*Math.Sign(e.Delta);}
  protected override bool IsInputKey(Keys key){
   switch(key&Keys.KeyCode){
    case Keys.Up:case Keys.Down:case Keys.Left:case Keys.Right:case Keys.Home:case Keys.End:return true;
    default:return base.IsInputKey(key);
   }
  }
  protected override void OnKeyDown(KeyEventArgs e){
   base.OnKeyDown(e);
   int step=e.Control?1:10;
   switch(e.KeyCode){
    case Keys.Up:case Keys.Right:Value+=step;break;
    case Keys.Down:case Keys.Left:Value-=step;break;
    case Keys.Home:Value=0;break;
    case Keys.End:Value=-600;break;
    default:return;
   }
   e.Handled=true;
  }
  protected override void OnGotFocus(EventArgs e){base.OnGotFocus(e);Invalidate();}
  protected override void OnLostFocus(EventArgs e){base.OnLostFocus(e);Invalidate();}
  public bool Active { get; set; }
  protected override void OnPaint(PaintEventArgs e){
   var g=e.Graphics;g.Clear(Surface);g.SmoothingMode=SmoothingMode.AntiAlias;
   float x=Width/2f,y0=Inset+Travel/2f,y=Inset+Travel*(600-gain)/1200f;
   int diameter=Math.Max(12,Width/4);
   using(var tick=new Pen(Color.FromArgb(53,66,74))){
    g.DrawLine(tick,0,Inset,Width,Inset);
    g.DrawLine(tick,0,Height-Inset-1,Width,Height-Inset-1);
   }
   using(var zero=new Pen(Color.FromArgb(79,102,111)))g.DrawLine(zero,0,y0,Width,y0);
   using(var rail=new Pen(Color.FromArgb(65,78,85),Math.Max(3,Width/13)))g.DrawLine(rail,x,Inset,x,Height-Inset-1);
   Color color=Active?Accent:Muted;
   using(var fill=new Pen(color,Math.Max(3,Width/13)))g.DrawLine(fill,x,y0,x,y);
   using(var knob=new SolidBrush(color))g.FillEllipse(knob,x-diameter/2f,y-diameter/2f,diameter,diameter);
   if(Focused)using(var focus=new Pen(Color.FromArgb(232,239,241)))
    g.DrawEllipse(focus,x-diameter/2f-3,y-diameter/2f-3,diameter+6,diameter+6);
  }
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
function Set-SpectralTheme($root,$primary,$parentCards){
 $root.BackColor=$script:SpectralBackground;$root.ForeColor=$script:SpectralInk
 $controls=@($root.Controls)
 $cards=@($controls | Where-Object {$_ -is [SpectralTheme.Card]})
 foreach($c in $controls){
  if($c -isnot [SpectralTheme.Card]){
   $candidates=if($parentCards -and $parentCards.ContainsKey($c)){$parentCards[$c]}else{$cards}
   foreach($card in $candidates){
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
 $logo=New-Object Windows.Forms.Label;$logo.Text='S';$logo.SetBounds(24,22,46,46);$logo.TextAlign='MiddleCenter';$logo.Font=New-Object Drawing.Font('Microsoft YaHei UI',17,[Drawing.FontStyle]::Bold)
 $form.Controls.Add($logo);$logo.BackColor=$script:SpectralAccent;$logo.ForeColor=$script:SpectralBackground
 $name=New-Object Windows.Forms.Label;$name.Text='Spectral AUDIO';$name.SetBounds(86,17,270,32);$name.Font=New-Object Drawing.Font('Microsoft YaHei UI',18,[Drawing.FontStyle]::Bold);$name.BackColor=$script:SpectralBackground;$name.ForeColor=$script:SpectralInk;$form.Controls.Add($name)
 $sub=New-Object Windows.Forms.Label;$sub.Text=$subtitle;$sub.SetBounds(87,53,620,24);$sub.Font=New-Object Drawing.Font('Microsoft YaHei UI',9);$sub.BackColor=$script:SpectralBackground;$sub.ForeColor=$script:SpectralMuted;$form.Controls.Add($sub)
}
